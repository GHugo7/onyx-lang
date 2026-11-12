//! Recursive-descent parser: tokens -> AST.

use crate::ast::*;
use crate::diagnostics::{Diagnostic, Span};
use crate::lexer::{lex, StrPiece, Tok, Token};

type PResult<T> = Result<T, Diagnostic>;

pub struct Parser<'a> {
    src: &'a str,
    toks: Vec<Token>,
    pos: usize,
    next_id: usize,
    /// Set while parsing an `if` / `while` / `for` header, where `name {` starts
    /// the body rather than a struct literal.
    no_struct: bool,
}

/// Parses the file stored at `src[start..end]`. Expression ids start at
/// `first_id`; the next free id is returned so that ids stay unique across files.
pub fn parse(src: &str, start: usize, end: usize, first_id: usize) -> PResult<(Program, usize)> {
    let toks = lex(src, start, end)?;
    let mut p = Parser { src, toks, pos: 0, next_id: first_id, no_struct: false };
    let mut items = Vec::new();
    while p.peek() != &Tok::Eof {
        items.push(p.item()?);
    }
    Ok((Program { items }, p.next_id))
}

impl<'a> Parser<'a> {
    // ---- token helpers ----

    fn peek(&self) -> &Tok {
        &self.toks[self.pos].tok
    }
    fn peek_at(&self, n: usize) -> &Tok {
        &self.toks[(self.pos + n).min(self.toks.len() - 1)].tok
    }
    fn span(&self) -> Span {
        self.toks[self.pos].span
    }
    fn prev_span(&self) -> Span {
        self.toks[self.pos.saturating_sub(1)].span
    }
    fn nl_before(&self) -> bool {
        self.toks[self.pos].nl_before
    }
    fn advance(&mut self) -> Token {
        let t = self.toks[self.pos].clone();
        if self.pos < self.toks.len() - 1 {
            self.pos += 1;
        }
        t
    }
    fn eat(&mut self, tok: &Tok) -> bool {
        if self.peek() == tok {
            self.advance();
            true
        } else {
            false
        }
    }
    fn unexpected<T>(&self, expected: &str) -> PResult<T> {
        Err(Diagnostic::new(
            "E0003",
            format!("expected {expected}, found {}", self.peek().describe()),
            self.span(),
        )
        .label(format!("expected {expected}")))
    }
    fn expect(&mut self, tok: Tok, expected: &str) -> PResult<Token> {
        if self.peek() == &tok {
            Ok(self.advance())
        } else {
            self.unexpected(expected)
        }
    }
    fn ident(&mut self, what: &str) -> PResult<(String, Span)> {
        if let Tok::Ident(name) = self.peek().clone() {
            let span = self.span();
            self.advance();
            Ok((name, span))
        } else {
            self.unexpected(what)
        }
    }
    fn mk(&mut self, kind: ExprKind, span: Span) -> Expr {
        let id = self.next_id;
        self.next_id += 1;
        Expr { id, span, kind }
    }
    fn with_no_struct<T>(&mut self, flag: bool, f: impl FnOnce(&mut Self) -> T) -> T {
        let saved = self.no_struct;
        self.no_struct = flag;
        let result = f(self);
        self.no_struct = saved;
        result
    }

    // ---- items ----

    fn item(&mut self) -> PResult<Item> {
        match self.peek() {
            Tok::Fn => Ok(Item::Fn(self.fn_decl(false)?)),
            Tok::Struct => self.struct_decl(),
            Tok::Interface => self.interface_decl(),
            Tok::Var | Tok::Const => Ok(Item::Global(self.let_stmt()?)),
            Tok::Import => {
                let start = self.advance().span;
                let path = match self.peek().clone() {
                    Tok::Str(pieces) => {
                        self.advance();
                        match pieces.as_slice() {
                            [StrPiece::Lit(s)] if !s.is_empty() => s.clone(),
                            _ => return Err(Diagnostic::new("E0003", "an import path must be a plain string", self.prev_span())),
                        }
                    }
                    _ => return self.unexpected("a file path, like `import \"utils\"`"),
                };
                let mut span = start.to(self.prev_span());
                let alias = if matches!(self.peek(), Tok::Ident(word) if word == "as") && !self.nl_before() {
                    self.advance();
                    let (name, name_span) = self.ident("a name for the module")?;
                    span = span.to(name_span);
                    Some(name)
                } else {
                    None
                };
                Ok(Item::Import { path, alias, span })
            }
            // `check` is only special here, in front of a test name.
            Tok::Ident(word) if word == "check" && matches!(self.peek_at(1), Tok::Str(_)) => {
                self.advance();
                let name = match self.peek().clone() {
                    Tok::Str(pieces) => {
                        self.advance();
                        match pieces.as_slice() {
                            [StrPiece::Lit(s)] => s.clone(),
                            _ => {
                                return Err(Diagnostic::new(
                                    "E0003",
                                    "a check name must be a plain string",
                                    self.prev_span(),
                                ))
                            }
                        }
                    }
                    _ => return self.unexpected("a test name, like `check \"adds numbers\" { ... }`"),
                };
                let body = self.block()?;
                Ok(Item::Check { name, body })
            }
            Tok::Ident(word) if word == "let" => {
                Err(Diagnostic::new("E0003", "Onyx declares variables with `var`, not `let`", self.span())
                    .label("replace with `var`"))
            }
            _ => Err(Diagnostic::new(
                "E0003",
                format!("expected a declaration, found {}", self.peek().describe()),
                self.span(),
            )
            .label("not allowed at the top level")
            .help("only `import`, `fn`, `struct`, `interface`, `var`, `const` and `check` can appear at the top level; put statements inside `fn main() { ... }`")),
        }
    }

    /// Parses `-> Type` / `-> Type!` if present.
    fn return_type(&mut self) -> PResult<(Option<TypeExpr>, bool)> {
        if !self.eat(&Tok::Arrow) {
            return Ok((None, false));
        }
        let ty = self.type_expr()?;
        let fallible = self.eat(&Tok::Bang);
        Ok((Some(ty), fallible))
    }

    fn params(&mut self, allow_self: bool) -> PResult<(bool, Vec<Param>)> {
        self.expect(Tok::LParen, "`(`")?;
        let mut has_self = false;
        let mut params = Vec::new();
        let mut first = true;
        while self.peek() != &Tok::RParen {
            let (name, span) = self.ident("a parameter name")?;
            if name == "self" && self.peek() != &Tok::Colon {
                if !allow_self || !first {
                    return Err(Diagnostic::new(
                        "E0003",
                        "`self` is only allowed as the first parameter of a method",
                        span,
                    ));
                }
                has_self = true;
            } else {
                if self.peek() != &Tok::Colon {
                    return Err(Diagnostic::new(
                        "E0003",
                        format!("parameter `{name}` needs a type"),
                        span,
                    )
                    .label("missing type")
                    .help(format!("write `{name}: int`, `{name}: string`, ...")));
                }
                self.advance();
                let ty = self.type_expr()?;
                params.push(Param { name, span: span.to(ty.span), ty });
            }
            first = false;
            if !self.eat(&Tok::Comma) {
                break;
            }
        }
        self.expect(Tok::RParen, "`)` or `,`")?;
        Ok((has_self, params))
    }

    fn fn_decl(&mut self, is_method: bool) -> PResult<FnDecl> {
        self.expect(Tok::Fn, "`fn`")?;
        let (name, name_span) = self.ident("a function name")?;
        let (has_self, params) = self.params(is_method)?;
        let (ret, fallible) = self.return_type()?;
        let body = self.with_no_struct(false, |p| p.block())?;
        Ok(FnDecl { name, name_span, has_self, params, ret, fallible, body })
    }

    fn struct_decl(&mut self) -> PResult<Item> {
        self.advance();
        let (name, name_span) = self.ident("a struct name")?;
        self.expect(Tok::LBrace, "`{`")?;
        let mut fields = Vec::new();
        let mut methods = Vec::new();
        while self.peek() != &Tok::RBrace {
            if self.peek() == &Tok::Fn {
                methods.push(self.fn_decl(true)?);
            } else {
                let (fname, fspan) = self.ident("a field name, a method or `}`")?;
                self.expect(Tok::Colon, "`:` followed by the field type")?;
                let ty = self.type_expr()?;
                fields.push(FieldDecl { name: fname, span: fspan, ty });
            }
            while self.eat(&Tok::Comma) || self.eat(&Tok::Semi) {}
        }
        self.advance();
        Ok(Item::Struct(StructDecl { name, name_span, fields, methods }))
    }

    fn interface_decl(&mut self) -> PResult<Item> {
        self.advance();
        let (name, name_span) = self.ident("an interface name")?;
        self.expect(Tok::LBrace, "`{`")?;
        let mut methods = Vec::new();
        while self.peek() != &Tok::RBrace {
            self.expect(Tok::Fn, "a method signature starting with `fn`, or `}`")?;
            let (mname, mspan) = self.ident("a method name")?;
            let (has_self, params) = self.params(true)?;
            if !has_self {
                return Err(Diagnostic::new(
                    "E0003",
                    "interface methods take `self` as their first parameter",
                    mspan,
                )
                .help(format!("write `fn {mname}(self, ...)`")));
            }
            let (ret, fallible) = self.return_type()?;
            methods.push(MethodSig { name: mname, name_span: mspan, params, ret, fallible });
            while self.eat(&Tok::Semi) {}
        }
        self.advance();
        Ok(Item::Interface(InterfaceDecl { name, name_span, methods }))
    }

    // ---- types ----

    fn type_expr(&mut self) -> PResult<TypeExpr> {
        let start = self.span();
        match self.peek().clone() {
            Tok::LBracket => {
                self.advance();
                let elem = self.type_expr()?;
                self.expect(Tok::RBracket, "`]`")?;
                Ok(TypeExpr { kind: TypeKind::List(Box::new(elem)), span: start.to(self.prev_span()) })
            }
            Tok::Chan => {
                self.advance();
                self.expect(Tok::Lt, "`<` (channel types look like `chan<int>`)")?;
                let elem = self.type_expr()?;
                self.expect(Tok::Gt, "`>`")?;
                Ok(TypeExpr { kind: TypeKind::Chan(Box::new(elem)), span: start.to(self.prev_span()) })
            }
            Tok::Fn => {
                self.advance();
                self.expect(Tok::LParen, "`(`")?;
                let mut params = Vec::new();
                while self.peek() != &Tok::RParen {
                    params.push(self.type_expr()?);
                    if !self.eat(&Tok::Comma) {
                        break;
                    }
                }
                self.expect(Tok::RParen, "`)`")?;
                let (ret, fallible) = self.return_type()?;
                Ok(TypeExpr {
                    kind: TypeKind::Fn { params, ret: ret.map(Box::new), fallible },
                    span: start.to(self.prev_span()),
                })
            }
            Tok::Ident(name) => {
                self.advance();
                if name == "map" && self.peek() == &Tok::Lt {
                    self.advance();
                    let key = self.type_expr()?;
                    self.expect(Tok::Comma, "`,` (map types look like `map<string, int>`)")?;
                    let value = self.type_expr()?;
                    self.expect(Tok::Gt, "`>`")?;
                    return Ok(TypeExpr {
                        kind: TypeKind::Map(Box::new(key), Box::new(value)),
                        span: start.to(self.prev_span()),
                    });
                }
                // `module.Type`
                if self.peek() == &Tok::Dot && matches!(self.peek_at(1), Tok::Ident(_)) {
                    self.advance();
                    let (item, item_span) = self.ident("a type name")?;
                    return Ok(TypeExpr { kind: TypeKind::Named(format!("{name}.{item}")), span: start.to(item_span) });
                }
                Ok(TypeExpr { kind: TypeKind::Named(name), span: start })
            }
            _ => self.unexpected("a type"),
        }
    }

    // ---- statements ----

    fn block(&mut self) -> PResult<Block> {
        let open = self.expect(Tok::LBrace, "`{`")?.span;
        let mut stmts = Vec::new();
        while self.peek() != &Tok::RBrace {
            if self.peek() == &Tok::Eof {
                return Err(Diagnostic::new("E0003", "this `{` is never closed", open)
                    .label("missing a matching `}`"));
            }
            if self.eat(&Tok::Semi) {
                continue;
            }
            stmts.push(self.stmt()?);
        }
        let close = self.advance().span;
        Ok(Block { stmts, span: open.to(close) })
    }

    fn let_stmt(&mut self) -> PResult<Stmt> {
        let start = self.span();
        let mutable = self.advance().tok == Tok::Var;
        let (name, name_span) = self.ident("a variable name")?;
        let ty = if self.eat(&Tok::Colon) { Some(self.type_expr()?) } else { None };
        if self.peek() == &Tok::Bang {
            return Err(Diagnostic::new("E0206", "`!` is only valid on a return type", self.span())
                .help("a variable holds a value, never an error; handle the call with `?`, `or` or `catch`"));
        }
        if self.peek() != &Tok::Eq {
            return Err(Diagnostic::new(
                "E0003",
                format!("variable `{name}` must be given a value"),
                name_span,
            )
            .help(format!("write `var {name} = ...`")));
        }
        self.advance();
        let init = self.with_no_struct(false, |p| p.expr())?;
        Ok(Stmt { span: start.to(init.span), kind: StmtKind::Let { name, name_span, mutable, ty, init } })
    }

    fn stmt(&mut self) -> PResult<Stmt> {
        let start = self.span();
        match self.peek() {
            Tok::Var | Tok::Const => self.let_stmt(),
            Tok::If => self.if_stmt(),
            Tok::While => {
                self.advance();
                let cond = self.with_no_struct(true, |p| p.expr())?;
                let body = self.with_no_struct(false, |p| p.block())?;
                Ok(Stmt { span: start.to(body.span), kind: StmtKind::While { cond, body } })
            }
            Tok::For => {
                self.advance();
                let (var, var_span) = self.ident("a loop variable name")?;
                self.expect(Tok::In, "`in` (loops look like `for item in list`)")?;
                let iter = self.with_no_struct(true, |p| p.expr())?;
                let body = self.with_no_struct(false, |p| p.block())?;
                Ok(Stmt { span: start.to(body.span), kind: StmtKind::For { var, var_span, iter, body } })
            }
            Tok::Return => {
                self.advance();
                let has_value = !self.nl_before()
                    && !matches!(self.peek(), Tok::RBrace | Tok::Semi | Tok::Eof);
                let value = if has_value { Some(self.expr()?) } else { None };
                Ok(Stmt { span: start.to(self.prev_span()), kind: StmtKind::Return(value) })
            }
            Tok::Break => {
                self.advance();
                Ok(Stmt { span: start, kind: StmtKind::Break })
            }
            Tok::Continue => {
                self.advance();
                Ok(Stmt { span: start, kind: StmtKind::Continue })
            }
            Tok::Fail => {
                self.advance();
                let value = self.expr()?;
                Ok(Stmt { span: start.to(value.span), kind: StmtKind::Fail(value) })
            }
            Tok::Fork => {
                self.advance();
                let body = self.with_no_struct(false, |p| p.block())?;
                Ok(Stmt { span: start.to(body.span), kind: StmtKind::Fork(body) })
            }
            Tok::LBrace => {
                let body = self.block()?;
                Ok(Stmt { span: body.span, kind: StmtKind::Block(body) })
            }
            Tok::Fn if matches!(self.peek_at(1), Tok::Ident(_)) => Err(Diagnostic::new(
                "E0003",
                "functions must be declared at the top level",
                self.span(),
            )
            .help("to create a function inside another one, use a lambda: `var f = fn(x: int) -> int { ... }`")),
            Tok::Ident(word) if word == "let" && matches!(self.peek_at(1), Tok::Ident(_)) => {
                Err(Diagnostic::new("E0003", "Onyx declares variables with `var`, not `let`", self.span())
                    .label("replace with `var`"))
            }
            _ => {
                let target = self.expr()?;
                let op = match self.peek() {
                    Tok::Eq => Some(AssignOp::Set),
                    Tok::PlusEq => Some(AssignOp::Add),
                    Tok::MinusEq => Some(AssignOp::Sub),
                    Tok::StarEq => Some(AssignOp::Mul),
                    Tok::SlashEq => Some(AssignOp::Div),
                    _ => None,
                };
                if let Some(op) = op {
                    self.advance();
                    let value = self.expr()?;
                    return Ok(Stmt {
                        span: start.to(value.span),
                        kind: StmtKind::Assign { target, op, value },
                    });
                }
                if self.peek() == &Tok::LArrow && !self.nl_before() {
                    self.advance();
                    let value = self.expr()?;
                    return Ok(Stmt {
                        span: start.to(value.span),
                        kind: StmtKind::Send { chan: target, value },
                    });
                }
                Ok(Stmt { span: target.span, kind: StmtKind::Expr(target) })
            }
        }
    }

    fn if_stmt(&mut self) -> PResult<Stmt> {
        let start = self.advance().span;
        let cond = self.with_no_struct(true, |p| p.expr())?;
        let then = self.with_no_struct(false, |p| p.block())?;
        let mut end = then.span;
        let els = if self.eat(&Tok::Else) {
            let stmt = if self.peek() == &Tok::If {
                self.if_stmt()?
            } else {
                let body = self.with_no_struct(false, |p| p.block())?;
                Stmt { span: body.span, kind: StmtKind::Block(body) }
            };
            end = stmt.span;
            Some(Box::new(stmt))
        } else {
            None
        };
        Ok(Stmt { span: start.to(end), kind: StmtKind::If { cond, then, els } })
    }

    // ---- expressions ----

    pub fn expr(&mut self) -> PResult<Expr> {
        let mut e = self.range()?;
        loop {
            match self.peek() {
                Tok::Or => {
                    self.advance();
                    let default = self.range()?;
                    let span = e.span.to(default.span);
                    e = self.mk(ExprKind::Or { expr: Box::new(e), default: Box::new(default) }, span);
                }
                Tok::Catch => {
                    self.advance();
                    let (name, name_span) = self.ident("a name for the error, like `catch err { ... }`")?;
                    let body = self.with_no_struct(false, |p| p.block())?;
                    let span = e.span.to(body.span);
                    e = self.mk(ExprKind::Catch { expr: Box::new(e), name, name_span, body }, span);
                }
                _ => return Ok(e),
            }
        }
    }

    fn range(&mut self) -> PResult<Expr> {
        let lo = self.binary(1)?;
        if self.eat(&Tok::DotDot) {
            let hi = self.binary(1)?;
            let span = lo.span.to(hi.span);
            return Ok(self.mk(ExprKind::Range { lo: Box::new(lo), hi: Box::new(hi) }, span));
        }
        Ok(lo)
    }

    fn binary(&mut self, min_prec: u8) -> PResult<Expr> {
        let mut lhs = self.unary()?;
        loop {
            let (op, prec) = match self.peek() {
                Tok::OrOr => (BinOp::Or, 1),
                Tok::AndAnd => (BinOp::And, 2),
                Tok::EqEq => (BinOp::Eq, 3),
                Tok::NotEq => (BinOp::NotEq, 3),
                Tok::Lt => (BinOp::Lt, 4),
                Tok::Le => (BinOp::Le, 4),
                Tok::Gt => (BinOp::Gt, 4),
                Tok::Ge => (BinOp::Ge, 4),
                Tok::Plus => (BinOp::Add, 5),
                // A `-` that starts a new line begins a new statement.
                Tok::Minus if !self.nl_before() => (BinOp::Sub, 5),
                Tok::Star => (BinOp::Mul, 6),
                Tok::Slash => (BinOp::Div, 6),
                Tok::Percent => (BinOp::Mod, 6),
                _ => break,
            };
            if prec < min_prec {
                break;
            }
            self.advance();
            let rhs = self.binary(prec + 1)?;
            let span = lhs.span.to(rhs.span);
            lhs = self.mk(ExprKind::Binary { op, lhs: Box::new(lhs), rhs: Box::new(rhs) }, span);
        }
        Ok(lhs)
    }

    fn unary(&mut self) -> PResult<Expr> {
        let start = self.span();
        match self.peek() {
            Tok::Bang => {
                self.advance();
                let e = self.unary()?;
                let span = start.to(e.span);
                Ok(self.mk(ExprKind::Unary { op: UnOp::Not, expr: Box::new(e) }, span))
            }
            Tok::Minus => {
                self.advance();
                let e = self.unary()?;
                let span = start.to(e.span);
                Ok(self.mk(ExprKind::Unary { op: UnOp::Neg, expr: Box::new(e) }, span))
            }
            Tok::LArrow => {
                self.advance();
                let e = self.unary()?;
                let span = start.to(e.span);
                Ok(self.mk(ExprKind::Recv(Box::new(e)), span))
            }
            _ => self.postfix(),
        }
    }

    fn args(&mut self) -> PResult<Vec<Expr>> {
        let mut args = Vec::new();
        self.with_no_struct(false, |p| {
            while p.peek() != &Tok::RParen {
                args.push(p.expr()?);
                if !p.eat(&Tok::Comma) {
                    break;
                }
            }
            p.expect(Tok::RParen, "`)` or `,`")?;
            Ok(())
        })?;
        Ok(args)
    }

    fn postfix(&mut self) -> PResult<Expr> {
        let mut e = self.primary()?;
        loop {
            match self.peek() {
                Tok::LParen if !self.nl_before() => {
                    self.advance();
                    let args = self.args()?;
                    let span = e.span.to(self.prev_span());
                    e = self.mk(ExprKind::Call { callee: Box::new(e), args }, span);
                }
                Tok::LBracket if !self.nl_before() => {
                    self.advance();
                    let index = self.with_no_struct(false, |p| p.expr())?;
                    self.expect(Tok::RBracket, "`]`")?;
                    let span = e.span.to(self.prev_span());
                    e = self.mk(ExprKind::Index { obj: Box::new(e), index: Box::new(index) }, span);
                }
                Tok::Dot => {
                    self.advance();
                    let (name, name_span) = self.ident("a field or method name")?;
                    let span = e.span.to(name_span);
                    // `module.Struct{...}`
                    if let ExprKind::Ident(module) = &e.kind {
                        if self.at_struct_literal() {
                            e = self.struct_literal(format!("{module}.{name}"), span)?;
                            continue;
                        }
                    }
                    e = self.mk(ExprKind::Field { obj: Box::new(e), name, name_span }, span);
                }
                Tok::Question if !self.nl_before() => {
                    self.advance();
                    let span = e.span.to(self.prev_span());
                    e = self.mk(ExprKind::Try(Box::new(e)), span);
                }
                _ => return Ok(e),
            }
        }
    }

    /// After an identifier: does `{` begin a struct literal?
    fn at_struct_literal(&self) -> bool {
        if self.peek() != &Tok::LBrace || self.nl_before() {
            return false;
        }
        match (self.peek_at(1), self.peek_at(2)) {
            (Tok::Ident(_), Tok::Colon) => true,
            (Tok::RBrace, _) => !self.no_struct,
            _ => false,
        }
    }

    fn primary(&mut self) -> PResult<Expr> {
        let start = self.span();
        match self.peek().clone() {
            Tok::Int(n) => {
                self.advance();
                Ok(self.mk(ExprKind::Int(n), start))
            }
            Tok::Float(n) => {
                self.advance();
                Ok(self.mk(ExprKind::Float(n), start))
            }
            Tok::True => {
                self.advance();
                Ok(self.mk(ExprKind::Bool(true), start))
            }
            Tok::False => {
                self.advance();
                Ok(self.mk(ExprKind::Bool(false), start))
            }
            Tok::Str(pieces) => {
                self.advance();
                let mut parts = Vec::new();
                for piece in pieces {
                    match piece {
                        StrPiece::Lit(s) => parts.push(StrPart::Lit(s)),
                        StrPiece::Code { start, end } => parts.push(StrPart::Expr(self.interpolation(start, end)?)),
                    }
                }
                Ok(self.mk(ExprKind::Str(parts), start))
            }
            Tok::Ident(name) => {
                self.advance();
                if self.at_struct_literal() {
                    return self.struct_literal(name, start);
                }
                Ok(self.mk(ExprKind::Ident(name), start))
            }
            Tok::LParen => {
                self.advance();
                let e = self.with_no_struct(false, |p| p.expr())?;
                self.expect(Tok::RParen, "`)`")?;
                Ok(e)
            }
            Tok::LBracket => {
                self.advance();
                let mut items = Vec::new();
                self.with_no_struct(false, |p| {
                    while p.peek() != &Tok::RBracket {
                        items.push(p.expr()?);
                        if !p.eat(&Tok::Comma) {
                            break;
                        }
                    }
                    p.expect(Tok::RBracket, "`]` or `,`")?;
                    Ok(())
                })?;
                let span = start.to(self.prev_span());
                Ok(self.mk(ExprKind::List(items), span))
            }
            Tok::LBrace => {
                self.advance();
                let mut entries = Vec::new();
                self.with_no_struct(false, |p| {
                    while p.peek() != &Tok::RBrace {
                        let key = p.expr()?;
                        p.expect(Tok::Colon, "`:` between a map key and its value")?;
                        let value = p.expr()?;
                        entries.push((key, value));
                        if !p.eat(&Tok::Comma) {
                            break;
                        }
                    }
                    p.expect(Tok::RBrace, "`}` or `,`")?;
                    Ok(())
                })?;
                let span = start.to(self.prev_span());
                Ok(self.mk(ExprKind::Map(entries), span))
            }
            Tok::Fn => {
                self.advance();
                let (_, params) = self.params(false)?;
                let (ret, fallible) = self.return_type()?;
                let body = self.with_no_struct(false, |p| p.block())?;
                let span = start.to(body.span);
                Ok(self.mk(ExprKind::Lambda { params, ret, fallible, body }, span))
            }
            Tok::Chan => {
                self.advance();
                self.expect(Tok::Lt, "`<` (create a channel with `chan<int>()`)")?;
                let elem = self.type_expr()?;
                self.expect(Tok::Gt, "`>`")?;
                self.expect(Tok::LParen, "`(` (create a channel with `chan<int>()`)")?;
                let cap = if self.peek() != &Tok::RParen {
                    Some(Box::new(self.with_no_struct(false, |p| p.expr())?))
                } else {
                    None
                };
                self.expect(Tok::RParen, "`)`")?;
                let span = start.to(self.prev_span());
                Ok(self.mk(ExprKind::ChanNew { elem, cap }, span))
            }
            _ => self.unexpected("an expression"),
        }
    }

    fn struct_literal(&mut self, name: String, name_span: Span) -> PResult<Expr> {
        self.advance(); // {
        let mut fields = Vec::new();
        self.with_no_struct(false, |p| {
            while p.peek() != &Tok::RBrace {
                let (fname, fspan) = p.ident("a field name")?;
                p.expect(Tok::Colon, "`:` followed by the field value")?;
                let value = p.expr()?;
                fields.push(FieldInit { name: fname, name_span: fspan, value });
                if !p.eat(&Tok::Comma) {
                    break;
                }
            }
            p.expect(Tok::RBrace, "`}` or `,`")?;
            Ok(())
        })?;
        let span = name_span.to(self.prev_span());
        Ok(self.mk(ExprKind::StructLit { name, name_span, fields }, span))
    }

    /// Parses the code inside a string's `{...}`.
    fn interpolation(&mut self, start: usize, end: usize) -> PResult<Expr> {
        if self.src[start..end].trim().is_empty() {
            return Err(Diagnostic::new(
                "E0003",
                "empty interpolation in string",
                Span::new(start.saturating_sub(1), end + 1),
            )
            .help("write `\\{` for a literal brace"));
        }
        let sub = lex(self.src, start, end)?;
        let saved_toks = std::mem::replace(&mut self.toks, sub);
        let saved_pos = std::mem::replace(&mut self.pos, 0);
        let result = self.with_no_struct(false, |p| {
            let e = p.expr()?;
            if p.peek() != &Tok::Eof {
                return p.unexpected("`}` to close the interpolation");
            }
            Ok(e)
        });
        self.toks = saved_toks;
        self.pos = saved_pos;
        result
    }
}
