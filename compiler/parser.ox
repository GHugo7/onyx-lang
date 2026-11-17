// Recursive-descent parser: tokens to syntax tree.
//
// Every function that reads something fails with "syntax" when the source is
// not what it expects, after noting the problem in the report.

import "ast"
import "diag"
import "lexer"

fn is_ident(t: lexer.Tok) -> bool {
    match t {
        Ident(_) {
            return true
        }
        else {
            return false
        }
    }
}

fn is_str(t: lexer.Tok) -> bool {
    match t {
        Str(_) {
            return true
        }
        else {
            return false
        }
    }
}

// How strongly a binary operator binds; 0 for a token that is not one.
fn precedence(t: lexer.Tok) -> int {
    match t {
        OrOr {
            return 1
        }
        AndAnd {
            return 2
        }
        EqEq, NotEq {
            return 3
        }
        Lt, Le, Gt, Ge {
            return 4
        }
        Plus, Minus, Pipe, Caret {
            return 5
        }
        Star, Slash, Percent, Amp, Shl, Shr {
            return 6
        }
        else {
            return 0
        }
    }
}

fn operator(t: lexer.Tok) -> ast.BinOp {
    match t {
        OrOr {
            return ast.BinOp.Or
        }
        AndAnd {
            return ast.BinOp.And
        }
        EqEq {
            return ast.BinOp.Eq
        }
        NotEq {
            return ast.BinOp.NotEq
        }
        Lt {
            return ast.BinOp.Lt
        }
        Le {
            return ast.BinOp.Le
        }
        Gt {
            return ast.BinOp.Gt
        }
        Ge {
            return ast.BinOp.Ge
        }
        Plus {
            return ast.BinOp.Add
        }
        Minus {
            return ast.BinOp.Sub
        }
        Star {
            return ast.BinOp.Mul
        }
        Slash {
            return ast.BinOp.Div
        }
        else {
            return ast.BinOp.Mod
        }
    }
}

// Operations on the bits of an int are calls to built-in functions:
// `a & b` is `bit_and(a, b)`. The function for a token, or "".
fn bit_function(t: lexer.Tok) -> string {
    match t {
        Pipe {
            return "bit_or"
        }
        Caret {
            return "bit_xor"
        }
        Amp {
            return "bit_and"
        }
        Shl {
            return "shift_left"
        }
        Shr {
            return "shift_right"
        }
        else {
            return ""
        }
    }
}

struct Parser {
    src: [int]
    toks: [lexer.Token]
    pos: int
    next_id: int
    // Set while parsing an `if` / `while` / `for` header, where `name \{`
    // starts the body rather than a struct literal.
    no_struct: bool
    report: diag.Report
    // Whether the parameter list read last started with `self`.
    saw_self: bool

    // ---- token helpers ----

    fn peek(self) -> lexer.Tok {
        return self.toks[self.pos].tok
    }

    fn peek_at(self, n: int) -> lexer.Tok {
        return self.toks[min(self.pos + n, self.toks.len() - 1)].tok
    }

    fn start(self) -> int {
        return self.toks[self.pos].start
    }

    fn end(self) -> int {
        return self.toks[self.pos].end
    }

    fn prev(self) -> lexer.Token {
        return self.toks[max(self.pos - 1, 0)]
    }

    fn nl_before(self) -> bool {
        return self.toks[self.pos].nl_before
    }

    fn advance(self) -> lexer.Token {
        var t = self.toks[self.pos]
        if self.pos < self.toks.len() - 1 {
            self.pos += 1
        }
        return t
    }

    fn eat(self, tok: lexer.Tok) -> bool {
        if self.peek() == tok {
            self.advance()
            return true
        }
        return false
    }

    // A token as an error message names it.
    fn describe(self, t: lexer.Token) -> string {
        match t.tok {
            Int(_), Float(_) {
                return "a number"
            }
            Str(_) {
                return "a string"
            }
            Eof {
                return "end of file"
            }
            else {
                return "`" + lexer.text_of(self.src, t.start, t.end) + "`"
            }
        }
    }

    fn problem(self, message: string, start: int, end: int) -> diag.Diag {
        return self.report.add("E0003", message, start, end)
    }

    // Notes that something else than `expected` was found here.
    fn unexpected(self, expected: string) {
        var t = self.toks[self.pos]
        var d = self.problem("expected {expected}, found {self.describe(t)}", t.start, t.end)
        d.label = "expected {expected}"
    }

    fn expect(self, tok: lexer.Tok, expected: string) -> lexer.Token! {
        if self.peek() == tok {
            return self.advance()
        }
        self.unexpected(expected)
        fail "syntax"
    }

    fn ident(self, what: string) -> ast.Name! {
        match self.peek() {
            Ident(name) {
                var t = self.advance()
                return ast.Name{text: name, start: t.start, end: t.end}
            }
            else {
                self.unexpected(what)
                fail "syntax"
            }
        }
    }

    fn mk(self, kind: ast.ExprKind, start: int, end: int) -> ast.Expr {
        var e = ast.Expr{id: self.next_id, start: start, end: end, kind: kind}
        self.next_id += 1
        return e
    }

    // An expression in a place where `name \{` may start a struct literal
    // (`allow`) or may not.
    fn expr_with(self, no_struct: bool) -> ast.Expr! {
        var saved = self.no_struct
        self.no_struct = no_struct
        var e = self.expr()?
        self.no_struct = saved
        return e
    }

    fn block_with(self, no_struct: bool) -> ast.Block! {
        var saved = self.no_struct
        self.no_struct = no_struct
        var b = self.block()?
        self.no_struct = saved
        return b
    }

    // ---- items ----

    fn item(self) -> ast.Item! {
        match self.peek() {
            Fn {
                return ast.Item.Fn(self.fn_decl(false)?)
            }
            Struct {
                return self.struct_decl()?
            }
            Enum {
                return self.enum_decl()?
            }
            Interface {
                return self.interface_decl()?
            }
            Var, Const {
                return ast.Item.Global(self.let_stmt()?)
            }
            Import {
                return self.import_decl()?
            }
            Ident(word) {
                // `check` is only special here, in front of a test name.
                if word == "check" && is_str(self.peek_at(1)) {
                    return self.check_decl()?
                }
                if word == "let" {
                    var d = self.problem("Onyx declares variables with `var`, not `let`", self.start(), self.end())
                    d.label = "replace with `var`"
                    fail "syntax"
                }
            }
            else {
            }
        }
        var t = self.toks[self.pos]
        var d = self.problem("expected a declaration, found {self.describe(t)}", t.start, t.end)
        d.label = "not allowed at the top level"
        d.help = "only `import`, `fn`, `struct`, `interface`, `var`, `const` and `check` can appear at the top level; put statements inside `fn main() \{ ... \}`"
        fail "syntax"
    }

    fn import_decl(self) -> ast.Item! {
        var start = self.advance().start
        var path = ""
        match self.peek() {
            Str(pieces) {
                self.advance()
                var plain = false
                if pieces.len() == 1 {
                    match pieces[0] {
                        Lit(text) {
                            path = text
                            plain = text != ""
                        }
                        else {
                        }
                    }
                }
                if !plain {
                    var p = self.prev()
                    self.problem("an import path must be a plain string", p.start, p.end)
                    fail "syntax"
                }
            }
            else {
                self.unexpected("a file path, like `import \"utils\"`")
                fail "syntax"
            }
        }
        var end = self.prev().end
        var alias: [string] = []
        var has_alias = false
        match self.peek() {
            Ident(word) {
                has_alias = word == "as" && !self.nl_before()
            }
            else {
            }
        }
        if has_alias {
            self.advance()
            var name = self.ident("a name for the module")?
            end = max(end, name.end)
            alias.push(name.text)
        }
        return ast.Item.Import(path, alias, start, end)
    }

    fn check_decl(self) -> ast.Item! {
        self.advance()
        var name = ""
        match self.peek() {
            Str(pieces) {
                self.advance()
                var plain = false
                if pieces.len() == 1 {
                    match pieces[0] {
                        Lit(text) {
                            name = text
                            plain = true
                        }
                        else {
                        }
                    }
                }
                if !plain {
                    var p = self.prev()
                    self.problem("a check name must be a plain string", p.start, p.end)
                    fail "syntax"
                }
            }
            else {
                self.unexpected("a test name, like `check \"adds numbers\" \{ ... \}`")
                fail "syntax"
            }
        }
        var body = self.block()?
        return ast.Item.Check(name, body)
    }

    // Parses `-> Type` / `-> Type!` if present; `fallible` says whether the
    // `!` was there.
    fn return_type(self) -> [ast.TypeExpr]! {
        var ret: [ast.TypeExpr] = []
        if self.eat(lexer.Tok.Arrow) {
            ret.push(self.type_expr()?)
        }
        return ret
    }

    // The parameters between parentheses. A `self` in front is not among
    // them: `saw_self` tells whether it was there.
    fn params(self, allow_self: bool) -> [ast.Param]! {
        self.expect(lexer.Tok.LParen, "`(`")?
        self.saw_self = false
        var params: [ast.Param] = []
        var first = true
        while self.peek() != lexer.Tok.RParen {
            var name = self.ident("a parameter name")?
            if name.text == "self" && self.peek() != lexer.Tok.Colon {
                if !allow_self || !first {
                    self.problem("`self` is only allowed as the first parameter of a method", name.start, name.end)
                    fail "syntax"
                }
                self.saw_self = true
            } else {
                if self.peek() != lexer.Tok.Colon {
                    var d = self.problem("parameter `{name.text}` needs a type", name.start, name.end)
                    d.label = "missing type"
                    d.help = "write `{name.text}: int`, `{name.text}: string`, ..."
                    fail "syntax"
                }
                self.advance()
                var ty = self.type_expr()?
                params.push(ast.Param{name: name.text, ty: ty, start: min(name.start, ty.start), end: max(name.end, ty.end)})
            }
            first = false
            if !self.eat(lexer.Tok.Comma) {
                break
            }
        }
        self.expect(lexer.Tok.RParen, "`)` or `,`")?
        return params
    }

    fn fn_decl(self, is_method: bool) -> ast.FnDecl! {
        self.expect(lexer.Tok.Fn, "`fn`")?
        var name = self.ident("a function name")?
        var params = self.params(is_method)?
        var has_self = self.saw_self
        var ret = self.return_type()?
        var fallible = ret.len() > 0 && self.eat(lexer.Tok.Bang)
        var body = self.block_with(false)?
        return ast.FnDecl{
            name: name.text,
            name_start: name.start,
            name_end: name.end,
            has_self: has_self,
            params: params,
            ret: ret,
            fallible: fallible,
            body: body
        }
    }

    fn struct_decl(self) -> ast.Item! {
        self.advance()
        var name = self.ident("a struct name")?
        self.expect(lexer.Tok.LBrace, "`\{`")?
        var fields: [ast.FieldDecl] = []
        var methods: [ast.FnDecl] = []
        while self.peek() != lexer.Tok.RBrace {
            if self.peek() == lexer.Tok.Fn {
                methods.push(self.fn_decl(true)?)
            } else {
                var field = self.ident("a field name, a method or `\}`")?
                self.expect(lexer.Tok.Colon, "`:` followed by the field type")?
                var ty = self.type_expr()?
                fields.push(ast.FieldDecl{name: field.text, ty: ty, start: field.start, end: field.end})
            }
            while self.eat(lexer.Tok.Comma) || self.eat(lexer.Tok.Semi) {
            }
        }
        self.advance()
        return ast.Item.Struct(ast.StructDecl{name: name.text, name_start: name.start, name_end: name.end, fields: fields, methods: methods})
    }

    fn enum_decl(self) -> ast.Item! {
        self.advance()
        var name = self.ident("an enum name")?
        self.expect(lexer.Tok.LBrace, "`\{`")?
        var variants: [ast.VariantDecl] = []
        while self.peek() != lexer.Tok.RBrace {
            var variant = self.ident("a variant name or `\}`")?
            var fields: [ast.TypeExpr] = []
            if self.eat(lexer.Tok.LParen) {
                while self.peek() != lexer.Tok.RParen {
                    // `radius: float` or just `float`
                    if is_ident(self.peek()) && self.peek_at(1) == lexer.Tok.Colon {
                        self.advance()
                        self.advance()
                    }
                    fields.push(self.type_expr()?)
                    if !self.eat(lexer.Tok.Comma) {
                        break
                    }
                }
                self.expect(lexer.Tok.RParen, "`)`")?
            }
            variants.push(ast.VariantDecl{name: variant.text, start: variant.start, end: variant.end, fields: fields})
            while self.eat(lexer.Tok.Comma) || self.eat(lexer.Tok.Semi) {
            }
        }
        self.advance()
        return ast.Item.Enum(ast.EnumDecl{name: name.text, name_start: name.start, name_end: name.end, variants: variants})
    }

    fn interface_decl(self) -> ast.Item! {
        self.advance()
        var name = self.ident("an interface name")?
        self.expect(lexer.Tok.LBrace, "`\{`")?
        var methods: [ast.MethodSig] = []
        while self.peek() != lexer.Tok.RBrace {
            self.expect(lexer.Tok.Fn, "a method signature starting with `fn`, or `\}`")?
            var method = self.ident("a method name")?
            var params = self.params(true)?
            if !self.saw_self {
                var d = self.problem("interface methods take `self` as their first parameter", method.start, method.end)
                d.help = "write `fn {method.text}(self, ...)`"
                fail "syntax"
            }
            var ret = self.return_type()?
            var fallible = ret.len() > 0 && self.eat(lexer.Tok.Bang)
            methods.push(ast.MethodSig{
                name: method.text,
                name_start: method.start,
                name_end: method.end,
                params: params,
                ret: ret,
                fallible: fallible
            })
            while self.eat(lexer.Tok.Semi) {
            }
        }
        self.advance()
        return ast.Item.Interface(ast.InterfaceDecl{name: name.text, name_start: name.start, name_end: name.end, methods: methods})
    }

    // ---- types ----

    // The `>` that ends `chan<...>`, `map<...>` or `weak<...>`. In
    // `chan<chan<int>>` the lexer saw `>>` as one token: it closes two.
    fn close_angle(self) -> void! {
        if self.peek() == lexer.Tok.Shr {
            self.toks[self.pos].tok = lexer.Tok.Gt
            return
        }
        self.expect(lexer.Tok.Gt, "`>`")?
    }

    fn type_expr(self) -> ast.TypeExpr! {
        var start = self.start()
        var first_end = self.end()
        match self.peek() {
            LBracket {
                self.advance()
                var elem = self.type_expr()?
                self.expect(lexer.Tok.RBracket, "`]`")?
                return ast.TypeExpr{kind: ast.TypeKind.List(elem), start: start, end: self.prev().end}
            }
            Chan {
                self.advance()
                self.expect(lexer.Tok.Lt, "`<` (channel types look like `chan<int>`)")?
                var elem = self.type_expr()?
                self.close_angle()?
                return ast.TypeExpr{kind: ast.TypeKind.Chan(elem), start: start, end: self.prev().end}
            }
            Fn {
                self.advance()
                self.expect(lexer.Tok.LParen, "`(`")?
                var params: [ast.TypeExpr] = []
                while self.peek() != lexer.Tok.RParen {
                    params.push(self.type_expr()?)
                    if !self.eat(lexer.Tok.Comma) {
                        break
                    }
                }
                self.expect(lexer.Tok.RParen, "`)`")?
                var ret = self.return_type()?
                var fallible = ret.len() > 0 && self.eat(lexer.Tok.Bang)
                return ast.TypeExpr{kind: ast.TypeKind.Fn(params, ret, fallible), start: start, end: self.prev().end}
            }
            Ident(name) {
                self.advance()
                if name == "map" && self.peek() == lexer.Tok.Lt {
                    self.advance()
                    var key = self.type_expr()?
                    self.expect(lexer.Tok.Comma, "`,` (map types look like `map<string, int>`)")?
                    var value = self.type_expr()?
                    self.close_angle()?
                    return ast.TypeExpr{kind: ast.TypeKind.Map(key, value), start: start, end: self.prev().end}
                }
                if name == "weak" && self.peek() == lexer.Tok.Lt {
                    self.advance()
                    var target = self.type_expr()?
                    self.close_angle()?
                    return ast.TypeExpr{kind: ast.TypeKind.Weak(target), start: start, end: self.prev().end}
                }
                // `module.Type`
                if self.peek() == lexer.Tok.Dot && is_ident(self.peek_at(1)) {
                    self.advance()
                    var item = self.ident("a type name")?
                    return ast.TypeExpr{kind: ast.TypeKind.Named(name + "." + item.text), start: start, end: item.end}
                }
                return ast.TypeExpr{kind: ast.TypeKind.Named(name), start: start, end: first_end}
            }
            else {
                self.unexpected("a type")
                fail "syntax"
            }
        }
    }

    // ---- statements ----

    fn block(self) -> ast.Block! {
        var open = self.expect(lexer.Tok.LBrace, "`\{`")?
        var stmts: [ast.Stmt] = []
        while self.peek() != lexer.Tok.RBrace {
            if self.peek() == lexer.Tok.Eof {
                var d = self.problem("this `\{` is never closed", open.start, open.end)
                d.label = "missing a matching `\}`"
                fail "syntax"
            }
            if self.eat(lexer.Tok.Semi) {
                continue
            }
            stmts.push(self.stmt()?)
        }
        var close = self.advance()
        return ast.Block{stmts: stmts, start: open.start, end: close.end}
    }

    fn let_stmt(self) -> ast.Stmt! {
        var start = self.start()
        var mutable = self.advance().tok == lexer.Tok.Var
        var name = self.ident("a variable name")?
        var ty: [ast.TypeExpr] = []
        if self.eat(lexer.Tok.Colon) {
            ty.push(self.type_expr()?)
        }
        if self.peek() == lexer.Tok.Bang {
            var d = self.report.add("E0206", "`!` is only valid on a return type", self.start(), self.end())
            d.help = "a variable holds a value, never an error; handle the call with `?`, `or` or `catch`"
            fail "syntax"
        }
        if self.peek() != lexer.Tok.Eq {
            var d = self.problem("variable `{name.text}` must be given a value", name.start, name.end)
            d.help = "write `var {name.text} = ...`"
            fail "syntax"
        }
        self.advance()
        var init = self.expr_with(false)?
        return ast.Stmt{
            kind: ast.StmtKind.Let(name.text, name.start, name.end, mutable, ty, init),
            start: min(start, init.start),
            end: init.end
        }
    }

    fn if_stmt(self) -> ast.Stmt! {
        var start = self.advance().start
        var cond = self.expr_with(true)?
        var then = self.block_with(false)?
        var end = then.end
        var els: [ast.Stmt] = []
        if self.eat(lexer.Tok.Else) {
            if self.peek() == lexer.Tok.If {
                els.push(self.if_stmt()?)
            } else {
                var body = self.block_with(false)?
                els.push(ast.Stmt{kind: ast.StmtKind.Block(body), start: body.start, end: body.end})
            }
            end = els[0].end
        }
        return ast.Stmt{kind: ast.StmtKind.If(cond, then, els), start: start, end: max(end, then.end)}
    }

    fn match_stmt(self) -> ast.Stmt! {
        var start = self.advance().start
        var subject = self.expr_with(true)?
        self.expect(lexer.Tok.LBrace, "`\{`")?
        var arms: [ast.MatchArm] = []
        var default: [ast.Block] = []
        while true {
            while self.eat(lexer.Tok.Semi) {
            }
            if self.peek() == lexer.Tok.RBrace {
                break
            }
            if self.eat(lexer.Tok.Else) {
                var body = self.block_with(false)?
                if default.len() > 0 {
                    self.problem("this `match` already has an `else`", body.start, body.end)
                    fail "syntax"
                }
                default.push(body)
                continue
            }
            var patterns: [ast.Pattern] = []
            while true {
                patterns.push(self.pattern()?)
                if !self.eat(lexer.Tok.Comma) {
                    break
                }
            }
            var body = self.block_with(false)?
            arms.push(ast.MatchArm{patterns: patterns, body: body})
        }
        var close = self.advance()
        return ast.Stmt{kind: ast.StmtKind.Match(subject, arms, default), start: start, end: close.end}
    }

    fn pattern(self) -> ast.Pattern! {
        if !is_ident(self.peek()) {
            var saved = self.no_struct
            self.no_struct = true
            var value = self.range()?
            self.no_struct = saved
            return ast.Pattern.Literal(value)
        }
        // `Variant`, `Variant(a, b)`, and the same after `Enum.` or `module.Enum.`
        var name = self.ident("a pattern")?
        while self.eat(lexer.Tok.Dot) {
            name = self.ident("a variant name")?
        }
        var bindings: [ast.Name] = []
        if self.eat(lexer.Tok.LParen) {
            while self.peek() != lexer.Tok.RParen {
                bindings.push(self.ident("a name for this value")?)
                if !self.eat(lexer.Tok.Comma) {
                    break
                }
            }
            self.expect(lexer.Tok.RParen, "`)`")?
        }
        return ast.Pattern.Variant(name.text, name.start, name.end, bindings)
    }

    fn stmt(self) -> ast.Stmt! {
        var first = self.toks[self.pos]
        var start = first.start
        match first.tok {
            Var, Const {
                return self.let_stmt()?
            }
            If {
                return self.if_stmt()?
            }
            Match {
                return self.match_stmt()?
            }
            While {
                self.advance()
                var cond = self.expr_with(true)?
                var body = self.block_with(false)?
                return ast.Stmt{kind: ast.StmtKind.While(cond, body), start: start, end: body.end}
            }
            For {
                self.advance()
                var name = self.ident("a loop variable name")?
                self.expect(lexer.Tok.In, "`in` (loops look like `for item in list`)")?
                var iter = self.expr_with(true)?
                var body = self.block_with(false)?
                return ast.Stmt{kind: ast.StmtKind.For(name.text, name.start, name.end, iter, body), start: start, end: body.end}
            }
            Return {
                self.advance()
                var value: [ast.Expr] = []
                var next = self.peek()
                var has_value = !self.nl_before() && next != lexer.Tok.RBrace && next != lexer.Tok.Semi && next != lexer.Tok.Eof
                if has_value {
                    value.push(self.expr()?)
                }
                return ast.Stmt{kind: ast.StmtKind.Return(value), start: start, end: max(first.end, self.prev().end)}
            }
            Break {
                self.advance()
                return ast.Stmt{kind: ast.StmtKind.Break, start: start, end: first.end}
            }
            Continue {
                self.advance()
                return ast.Stmt{kind: ast.StmtKind.Continue, start: start, end: first.end}
            }
            Fail {
                self.advance()
                var value = self.expr()?
                return ast.Stmt{kind: ast.StmtKind.Fail(value), start: start, end: value.end}
            }
            Fork {
                self.advance()
                var body = self.block_with(false)?
                return ast.Stmt{kind: ast.StmtKind.Fork(body), start: start, end: body.end}
            }
            LBrace {
                var body = self.block()?
                return ast.Stmt{kind: ast.StmtKind.Block(body), start: body.start, end: body.end}
            }
            Fn {
                if is_ident(self.peek_at(1)) {
                    var d = self.problem("functions must be declared at the top level", first.start, first.end)
                    d.help = "to create a function inside another one, use a lambda: `var f = fn(x: int) -> int \{ ... \}`"
                    fail "syntax"
                }
            }
            Ident(word) {
                if word == "let" && is_ident(self.peek_at(1)) {
                    var d = self.problem("Onyx declares variables with `var`, not `let`", first.start, first.end)
                    d.label = "replace with `var`"
                    fail "syntax"
                }
            }
            else {
            }
        }
        var target = self.expr()?
        var op = ast.AssignOp.Set
        var assigns = true
        match self.peek() {
            Eq {
                op = ast.AssignOp.Set
            }
            PlusEq {
                op = ast.AssignOp.Add
            }
            MinusEq {
                op = ast.AssignOp.Sub
            }
            StarEq {
                op = ast.AssignOp.Mul
            }
            SlashEq {
                op = ast.AssignOp.Div
            }
            else {
                assigns = false
            }
        }
        if assigns {
            self.advance()
            var value = self.expr()?
            return ast.Stmt{kind: ast.StmtKind.Assign(target, op, value), start: min(start, value.start), end: max(first.end, value.end)}
        }
        if self.peek() == lexer.Tok.LArrow && !self.nl_before() {
            self.advance()
            var value = self.expr()?
            return ast.Stmt{kind: ast.StmtKind.Send(target, value), start: min(start, value.start), end: max(first.end, value.end)}
        }
        return ast.Stmt{kind: ast.StmtKind.Expr(target), start: target.start, end: target.end}
    }

    // ---- expressions ----

    fn expr(self) -> ast.Expr! {
        var e = self.range()?
        while true {
            if self.peek() == lexer.Tok.Or {
                self.advance()
                var default = self.range()?
                e = self.mk(ast.ExprKind.Or(e, default), min(e.start, default.start), max(e.end, default.end))
            } else if self.peek() == lexer.Tok.Catch {
                self.advance()
                var name = self.ident("a name for the error, like `catch err \{ ... \}`")?
                var body = self.block_with(false)?
                e = self.mk(ast.ExprKind.Catch(e, name.text, name.start, name.end, body), min(e.start, body.start), max(e.end, body.end))
            } else {
                break
            }
        }
        return e
    }

    fn range(self) -> ast.Expr! {
        var lo = self.binary(1)?
        if self.eat(lexer.Tok.DotDot) {
            var hi = self.binary(1)?
            return self.mk(ast.ExprKind.Range(lo, hi), min(lo.start, hi.start), max(lo.end, hi.end))
        }
        return lo
    }

    fn binary(self, min_prec: int) -> ast.Expr! {
        var lhs = self.unary()?
        while true {
            var t = self.toks[self.pos]
            var prec = precedence(t.tok)
            // A `-` that starts a new line begins a new statement.
            if t.tok == lexer.Tok.Minus && t.nl_before {
                prec = 0
            }
            if prec == 0 || prec < min_prec {
                break
            }
            self.advance()
            var rhs = self.binary(prec + 1)?
            var start = min(lhs.start, rhs.start)
            var end = max(lhs.end, rhs.end)
            var function = bit_function(t.tok)
            if function != "" {
                var callee = self.mk(ast.ExprKind.Ident(function), t.start, t.end)
                lhs = self.mk(ast.ExprKind.Call(callee, [lhs, rhs]), start, end)
            } else {
                lhs = self.mk(ast.ExprKind.Binary(operator(t.tok), lhs, rhs), start, end)
            }
        }
        return lhs
    }

    fn unary(self) -> ast.Expr! {
        var first = self.toks[self.pos]
        var start = first.start
        match first.tok {
            Bang {
                self.advance()
                var e = self.unary()?
                return self.mk(ast.ExprKind.Unary(ast.UnOp.Not, e), min(start, e.start), max(first.end, e.end))
            }
            Minus {
                self.advance()
                var e = self.unary()?
                return self.mk(ast.ExprKind.Unary(ast.UnOp.Neg, e), min(start, e.start), max(first.end, e.end))
            }
            LArrow {
                self.advance()
                var e = self.unary()?
                return self.mk(ast.ExprKind.Recv(e), min(start, e.start), max(first.end, e.end))
            }
            Tilde {
                self.advance()
                var e = self.unary()?
                var callee = self.mk(ast.ExprKind.Ident("bit_not"), first.start, first.end)
                return self.mk(ast.ExprKind.Call(callee, [e]), min(start, e.start), max(first.end, e.end))
            }
            else {
                return self.postfix()?
            }
        }
    }

    fn args(self) -> [ast.Expr]! {
        var args: [ast.Expr] = []
        var saved = self.no_struct
        self.no_struct = false
        while self.peek() != lexer.Tok.RParen {
            args.push(self.expr()?)
            if !self.eat(lexer.Tok.Comma) {
                break
            }
        }
        self.expect(lexer.Tok.RParen, "`)` or `,`")?
        self.no_struct = saved
        return args
    }

    fn postfix(self) -> ast.Expr! {
        var e = self.primary()?
        while true {
            var t = self.toks[self.pos]
            if t.tok == lexer.Tok.LParen && !t.nl_before {
                self.advance()
                var args = self.args()?
                e = self.mk(ast.ExprKind.Call(e, args), e.start, max(e.end, self.prev().end))
            } else if t.tok == lexer.Tok.LBracket && !t.nl_before {
                self.advance()
                var index = self.expr_with(false)?
                self.expect(lexer.Tok.RBracket, "`]`")?
                e = self.mk(ast.ExprKind.Index(e, index), e.start, max(e.end, self.prev().end))
            } else if t.tok == lexer.Tok.Dot {
                self.advance()
                var name = self.ident("a field or method name")?
                var start = min(e.start, name.start)
                var end = max(e.end, name.end)
                // `module.Struct\{...\}`
                var module = ""
                match e.kind {
                    Ident(word) {
                        module = word
                    }
                    else {
                    }
                }
                if module != "" && self.at_struct_literal() {
                    e = self.struct_literal(module + "." + name.text, start, end)?
                    continue
                }
                e = self.mk(ast.ExprKind.Field(e, name.text, name.start, name.end), start, end)
            } else if t.tok == lexer.Tok.Question && !t.nl_before {
                self.advance()
                e = self.mk(ast.ExprKind.Try(e), e.start, max(e.end, self.prev().end))
            } else {
                break
            }
        }
        return e
    }

    // After an identifier: does `\{` begin a struct literal?
    fn at_struct_literal(self) -> bool {
        if self.peek() != lexer.Tok.LBrace || self.nl_before() {
            return false
        }
        if is_ident(self.peek_at(1)) && self.peek_at(2) == lexer.Tok.Colon {
            return true
        }
        if self.peek_at(1) == lexer.Tok.RBrace {
            return !self.no_struct
        }
        return false
    }

    fn primary(self) -> ast.Expr! {
        var first = self.toks[self.pos]
        var start = first.start
        var end = first.end
        match first.tok {
            Int(n) {
                self.advance()
                return self.mk(ast.ExprKind.Int(n), start, end)
            }
            Float(x) {
                self.advance()
                return self.mk(ast.ExprKind.Float(x), start, end)
            }
            True {
                self.advance()
                return self.mk(ast.ExprKind.Bool(true), start, end)
            }
            False {
                self.advance()
                return self.mk(ast.ExprKind.Bool(false), start, end)
            }
            Str(pieces) {
                self.advance()
                var parts: [ast.StrPart] = []
                for piece in pieces {
                    match piece {
                        Lit(text) {
                            parts.push(ast.StrPart.Lit(text))
                        }
                        Code(from, to) {
                            parts.push(ast.StrPart.Code(self.interpolation(from, to)?))
                        }
                    }
                }
                return self.mk(ast.ExprKind.Str(parts), start, end)
            }
            Ident(name) {
                self.advance()
                if self.at_struct_literal() {
                    return self.struct_literal(name, start, end)?
                }
                return self.mk(ast.ExprKind.Ident(name), start, end)
            }
            LParen {
                self.advance()
                var e = self.expr_with(false)?
                self.expect(lexer.Tok.RParen, "`)`")?
                return e
            }
            LBracket {
                self.advance()
                var items: [ast.Expr] = []
                var saved = self.no_struct
                self.no_struct = false
                while self.peek() != lexer.Tok.RBracket {
                    items.push(self.expr()?)
                    if !self.eat(lexer.Tok.Comma) {
                        break
                    }
                }
                self.expect(lexer.Tok.RBracket, "`]` or `,`")?
                self.no_struct = saved
                return self.mk(ast.ExprKind.List(items), start, max(end, self.prev().end))
            }
            LBrace {
                self.advance()
                var entries: [ast.Entry] = []
                var saved = self.no_struct
                self.no_struct = false
                while self.peek() != lexer.Tok.RBrace {
                    var key = self.expr()?
                    self.expect(lexer.Tok.Colon, "`:` between a map key and its value")?
                    var value = self.expr()?
                    entries.push(ast.Entry{key: key, value: value})
                    if !self.eat(lexer.Tok.Comma) {
                        break
                    }
                }
                self.expect(lexer.Tok.RBrace, "`\}` or `,`")?
                self.no_struct = saved
                return self.mk(ast.ExprKind.Map(entries), start, max(end, self.prev().end))
            }
            Fn {
                self.advance()
                var params = self.params(false)?
                var ret = self.return_type()?
                var fallible = ret.len() > 0 && self.eat(lexer.Tok.Bang)
                var body = self.block_with(false)?
                return self.mk(ast.ExprKind.Lambda(params, ret, fallible, body), min(start, body.start), max(end, body.end))
            }
            Chan {
                self.advance()
                self.expect(lexer.Tok.Lt, "`<` (create a channel with `chan<int>()`)")?
                var elem = self.type_expr()?
                self.close_angle()?
                self.expect(lexer.Tok.LParen, "`(` (create a channel with `chan<int>()`)")?
                var cap: [ast.Expr] = []
                if self.peek() != lexer.Tok.RParen {
                    cap.push(self.expr_with(false)?)
                }
                self.expect(lexer.Tok.RParen, "`)`")?
                return self.mk(ast.ExprKind.ChanNew(elem, cap), start, max(end, self.prev().end))
            }
            else {
                self.unexpected("an expression")
                fail "syntax"
            }
        }
    }

    fn struct_literal(self, name: string, name_start: int, name_end: int) -> ast.Expr! {
        self.advance()
        var fields: [ast.FieldInit] = []
        var saved = self.no_struct
        self.no_struct = false
        while self.peek() != lexer.Tok.RBrace {
            var field = self.ident("a field name")?
            self.expect(lexer.Tok.Colon, "`:` followed by the field value")?
            var value = self.expr()?
            fields.push(ast.FieldInit{name: field.text, name_start: field.start, name_end: field.end, value: value})
            if !self.eat(lexer.Tok.Comma) {
                break
            }
        }
        self.expect(lexer.Tok.RBrace, "`\}` or `,`")?
        self.no_struct = saved
        return self.mk(ast.ExprKind.StructLit(name, name_start, name_end, fields), name_start, max(name_end, self.prev().end))
    }

    // Parses the code inside the braces of a string.
    fn interpolation(self, start: int, end: int) -> ast.Expr! {
        if lexer.text_of(self.src, start, end).trim() == "" {
            var d = self.problem("empty interpolation in string", max(start - 1, 0), end + 1)
            d.help = "write `\\\{` for a literal brace"
            fail "syntax"
        }
        var sub = lexer.lex(self.src, start, end, self.report)?
        var saved_toks = self.toks
        var saved_pos = self.pos
        var saved = self.no_struct
        self.toks = sub
        self.pos = 0
        self.no_struct = false
        var e = self.expr()?
        if self.peek() != lexer.Tok.Eof {
            self.unexpected("`\}` to close the interpolation")
            fail "syntax"
        }
        self.toks = saved_toks
        self.pos = saved_pos
        self.no_struct = saved
        return e
    }
}

// Parses the bytes of `src` from `start` to `end`. Expression ids start at
// `first_id`.
fn parse(src: [int], start: int, end: int, first_id: int, report: diag.Report) -> ast.Program! {
    var toks = lexer.lex(src, start, end, report)?
    var p = Parser{src: src, toks: toks, pos: 0, next_id: first_id, no_struct: false, report: report, saw_self: false}
    var items: [ast.Item] = []
    while p.peek() != lexer.Tok.Eof {
        items.push(p.item()?)
    }
    return ast.Program{items: items}
}
