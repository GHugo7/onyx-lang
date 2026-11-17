//! Prints a syntax tree as text, one node per line, children indented.
//!
//! This is the reference for the compiler written in Onyx (compiler/), whose
//! parser must print exactly the same thing for the same file.

use crate::ast::*;
use crate::diagnostics::Span;

pub struct Dump<'a> {
    src: &'a str,
    pub out: String,
    /// Shows the id of every expression (`#12`).
    pub ids: bool,
}

pub fn quote(s: &str) -> String {
    let mut out = String::from("\"");
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            '\0' => out.push_str("\\0"),
            other => out.push(other),
        }
    }
    out.push('"');
    out
}

fn at(span: Span) -> String {
    format!("{}:{}", span.start, span.end)
}

impl<'a> Dump<'a> {
    pub fn new(src: &'a str) -> Dump<'a> {
        Dump { src, out: String::new(), ids: false }
    }

    fn line(&mut self, depth: usize, text: &str) {
        for _ in 0..depth {
            self.out.push_str("  ");
        }
        self.out.push_str(text);
        self.out.push('\n');
    }

    pub fn program(&mut self, program: &Program) {
        for item in &program.items {
            match item {
                Item::Fn(f) => self.function(0, f),
                Item::Struct(s) => {
                    self.line(0, &format!("struct {} {}", s.name, at(s.name_span)));
                    for f in &s.fields {
                        self.line(1, &format!("field {} {}", f.name, at(f.span)));
                        self.ty(2, &f.ty);
                    }
                    for m in &s.methods {
                        self.function(1, m);
                    }
                }
                Item::Interface(i) => {
                    self.line(0, &format!("interface {} {}", i.name, at(i.name_span)));
                    for m in &i.methods {
                        self.line(1, &format!("method {} {} fallible={}", m.name, at(m.name_span), m.fallible as u8));
                        self.params(2, &m.params);
                        if let Some(ret) = &m.ret {
                            self.line(2, "ret");
                            self.ty(3, ret);
                        }
                    }
                }
                Item::Enum(e) => {
                    self.line(0, &format!("enum {} {}", e.name, at(e.name_span)));
                    for v in &e.variants {
                        self.line(1, &format!("variant {} {}", v.name, at(v.span)));
                        for field in &v.fields {
                            self.ty(2, field);
                        }
                    }
                }
                Item::Global(stmt) => {
                    self.line(0, "global");
                    self.stmt(1, stmt);
                }
                Item::Check { name, body } => {
                    self.line(0, &format!("check {}", quote(name)));
                    self.block(1, body);
                }
                Item::Import { path, alias, span } => {
                    self.line(0, &format!("import {} {} {}", quote(path), alias.as_deref().unwrap_or("-"), at(*span)));
                }
            }
        }
    }

    fn function(&mut self, depth: usize, f: &FnDecl) {
        self.line(depth, &format!("fn {} {} self={} fallible={}", f.name, at(f.name_span), f.has_self as u8, f.fallible as u8));
        self.params(depth + 1, &f.params);
        if let Some(ret) = &f.ret {
            self.line(depth + 1, "ret");
            self.ty(depth + 2, ret);
        }
        self.block(depth + 1, &f.body);
    }

    fn params(&mut self, depth: usize, params: &[Param]) {
        for p in params {
            self.line(depth, &format!("param {} {}", p.name, at(p.span)));
            self.ty(depth + 1, &p.ty);
        }
    }

    fn ty(&mut self, depth: usize, t: &TypeExpr) {
        match &t.kind {
            TypeKind::Named(name) => self.line(depth, &format!("type Named {name} {}", at(t.span))),
            TypeKind::List(elem) => {
                self.line(depth, &format!("type List {}", at(t.span)));
                self.ty(depth + 1, elem);
            }
            TypeKind::Chan(elem) => {
                self.line(depth, &format!("type Chan {}", at(t.span)));
                self.ty(depth + 1, elem);
            }
            TypeKind::Weak(elem) => {
                self.line(depth, &format!("type Weak {}", at(t.span)));
                self.ty(depth + 1, elem);
            }
            TypeKind::Map(key, value) => {
                self.line(depth, &format!("type Map {}", at(t.span)));
                self.ty(depth + 1, key);
                self.ty(depth + 1, value);
            }
            TypeKind::Fn { params, ret, fallible } => {
                self.line(depth, &format!("type Fn {} fallible={}", at(t.span), *fallible as u8));
                for p in params {
                    self.ty(depth + 1, p);
                }
                if let Some(ret) = ret {
                    self.line(depth + 1, "ret");
                    self.ty(depth + 2, ret);
                }
            }
        }
    }

    fn block(&mut self, depth: usize, block: &Block) {
        self.line(depth, &format!("block {}", at(block.span)));
        for stmt in &block.stmts {
            self.stmt(depth + 1, stmt);
        }
    }

    fn stmt(&mut self, depth: usize, stmt: &Stmt) {
        let span = at(stmt.span);
        match &stmt.kind {
            StmtKind::Let { name, name_span, mutable, ty, init } => {
                self.line(depth, &format!("let {name} {} mutable={} {span}", at(*name_span), *mutable as u8));
                if let Some(ty) = ty {
                    self.ty(depth + 1, ty);
                }
                self.expr(depth + 1, init);
            }
            StmtKind::Assign { target, op, value } => {
                self.line(depth, &format!("assign {op:?} {span}"));
                self.expr(depth + 1, target);
                self.expr(depth + 1, value);
            }
            StmtKind::Expr(e) => {
                self.line(depth, &format!("expr {span}"));
                self.expr(depth + 1, e);
            }
            StmtKind::If { cond, then, els } => {
                self.line(depth, &format!("if {span}"));
                self.expr(depth + 1, cond);
                self.block(depth + 1, then);
                if let Some(other) = els {
                    self.stmt(depth + 1, other);
                }
            }
            StmtKind::While { cond, body } => {
                self.line(depth, &format!("while {span}"));
                self.expr(depth + 1, cond);
                self.block(depth + 1, body);
            }
            StmtKind::For { var, var_span, iter, body } => {
                self.line(depth, &format!("for {var} {} {span}", at(*var_span)));
                self.expr(depth + 1, iter);
                self.block(depth + 1, body);
            }
            StmtKind::Return(value) => {
                self.line(depth, &format!("return {span}"));
                if let Some(value) = value {
                    self.expr(depth + 1, value);
                }
            }
            StmtKind::Break => self.line(depth, &format!("break {span}")),
            StmtKind::Continue => self.line(depth, &format!("continue {span}")),
            StmtKind::Fail(value) => {
                self.line(depth, &format!("fail {span}"));
                self.expr(depth + 1, value);
            }
            StmtKind::Fork(body) => {
                self.line(depth, &format!("fork {span}"));
                self.block(depth + 1, body);
            }
            StmtKind::Send { chan, value } => {
                self.line(depth, &format!("send {span}"));
                self.expr(depth + 1, chan);
                self.expr(depth + 1, value);
            }
            StmtKind::Block(body) => {
                self.line(depth, &format!("blockstmt {span}"));
                self.block(depth + 1, body);
            }
            StmtKind::Match { subject, arms, default } => {
                self.line(depth, &format!("match {span}"));
                self.expr(depth + 1, subject);
                for arm in arms {
                    self.line(depth + 1, "arm");
                    for pattern in &arm.patterns {
                        match pattern {
                            Pattern::Literal(value) => {
                                self.line(depth + 2, "pat-lit");
                                self.expr(depth + 3, value);
                            }
                            Pattern::Variant { name, span, bindings } => {
                                self.line(depth + 2, &format!("pat-variant {name} {}", at(*span)));
                                for (binding, binding_span) in bindings {
                                    self.line(depth + 3, &format!("bind {binding} {}", at(*binding_span)));
                                }
                            }
                        }
                    }
                    self.block(depth + 2, &arm.body);
                }
                if let Some(body) = default {
                    self.line(depth + 1, "default");
                    self.block(depth + 2, body);
                }
            }
        }
    }

    fn expr(&mut self, depth: usize, e: &Expr) {
        let span = if self.ids { format!("{} #{}", at(e.span), e.id) } else { at(e.span) };
        match &e.kind {
            ExprKind::Int(n) => self.line(depth, &format!("Int {n} {span}")),
            ExprKind::Float(x) if self.ids => {
                // A float may have been computed by the compiler: its bits say exactly which.
                let text = &self.src[e.span.start..e.span.end];
                self.line(depth, &format!("Float {text} {span} bits={}", x.to_bits() as i64));
            }
            ExprKind::Float(_) => {
                let text = &self.src[e.span.start..e.span.end];
                self.line(depth, &format!("Float {text} {span}"));
            }
            ExprKind::Bool(b) => self.line(depth, &format!("Bool {} {span}", *b as u8)),
            ExprKind::Str(parts) => {
                self.line(depth, &format!("Str {span}"));
                for part in parts {
                    match part {
                        StrPart::Lit(text) => self.line(depth + 1, &format!("lit {}", quote(text))),
                        StrPart::Expr(inner) => self.expr(depth + 1, inner),
                    }
                }
            }
            ExprKind::Ident(name) => self.line(depth, &format!("Ident {name} {span}")),
            ExprKind::List(items) => {
                self.line(depth, &format!("List {span}"));
                for item in items {
                    self.expr(depth + 1, item);
                }
            }
            ExprKind::Map(entries) => {
                self.line(depth, &format!("Map {span}"));
                for (key, value) in entries {
                    self.expr(depth + 1, key);
                    self.expr(depth + 1, value);
                }
            }
            ExprKind::StructLit { name, name_span, fields } => {
                self.line(depth, &format!("StructLit {name} {} {span}", at(*name_span)));
                for f in fields {
                    self.line(depth + 1, &format!("init {} {}", f.name, at(f.name_span)));
                    self.expr(depth + 2, &f.value);
                }
            }
            ExprKind::Unary { op, expr } => {
                self.line(depth, &format!("Unary {op:?} {span}"));
                self.expr(depth + 1, expr);
            }
            ExprKind::Binary { op, lhs, rhs } => {
                self.line(depth, &format!("Binary {op:?} {span}"));
                self.expr(depth + 1, lhs);
                self.expr(depth + 1, rhs);
            }
            ExprKind::Call { callee, args } => {
                self.line(depth, &format!("Call {span}"));
                self.expr(depth + 1, callee);
                for arg in args {
                    self.expr(depth + 1, arg);
                }
            }
            ExprKind::Field { obj, name, name_span } => {
                self.line(depth, &format!("Field {name} {} {span}", at(*name_span)));
                self.expr(depth + 1, obj);
            }
            ExprKind::Index { obj, index } => {
                self.line(depth, &format!("Index {span}"));
                self.expr(depth + 1, obj);
                self.expr(depth + 1, index);
            }
            ExprKind::Lambda { params, ret, fallible, body } => {
                self.line(depth, &format!("Lambda fallible={} {span}", *fallible as u8));
                self.params(depth + 1, params);
                if let Some(ret) = ret {
                    self.line(depth + 1, "ret");
                    self.ty(depth + 2, ret);
                }
                self.block(depth + 1, body);
            }
            ExprKind::Try(inner) => {
                self.line(depth, &format!("Try {span}"));
                self.expr(depth + 1, inner);
            }
            ExprKind::Or { expr, default } => {
                self.line(depth, &format!("Or {span}"));
                self.expr(depth + 1, expr);
                self.expr(depth + 1, default);
            }
            ExprKind::Catch { expr, name, name_span, body } => {
                self.line(depth, &format!("Catch {name} {} {span}", at(*name_span)));
                self.expr(depth + 1, expr);
                self.block(depth + 1, body);
            }
            ExprKind::Recv(chan) => {
                self.line(depth, &format!("Recv {span}"));
                self.expr(depth + 1, chan);
            }
            ExprKind::ChanNew { elem, cap } => {
                self.line(depth, &format!("ChanNew {span}"));
                self.ty(depth + 1, elem);
                if let Some(cap) = cap {
                    self.expr(depth + 1, cap);
                }
            }
            ExprKind::Range { lo, hi } => {
                self.line(depth, &format!("Range {span}"));
                self.expr(depth + 1, lo);
                self.expr(depth + 1, hi);
            }
        }
    }
}
