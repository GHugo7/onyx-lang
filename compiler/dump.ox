// Prints a syntax tree as text, one node per line, children indented: the
// same text as `onyx ast` of the compiler written in Rust, which is how the
// two parsers are compared.

import "ast"
import "lexer"

// The name of a variant, as it is written in its enum: `str` gives
// `module.Enum.Variant(...)`.
fn variant_name(shown: string) -> string {
    var head = shown.split("(")[0]
    var parts = head.split(".")
    return parts[parts.len() - 1]
}

fn quote(text: string) -> string {
    var out = "\""
    for c in text {
        match c {
            "\\" {
                out += "\\\\"
            }
            "\"" {
                out += "\\\""
            }
            "\n" {
                out += "\\n"
            }
            "\t" {
                out += "\\t"
            }
            "\r" {
                out += "\\r"
            }
            "\0" {
                out += "\\0"
            }
            else {
                out += c
            }
        }
    }
    return out + "\""
}

fn flag(b: bool) -> string {
    if b {
        return "1"
    }
    return "0"
}

struct Dump {
    src: [int]
    lines: [string]
    // Also print the id of every expression, and the exact bits of floats
    // (as `onyx lowered` does).
    ids: bool

    fn line(self, depth: int, text: string) {
        self.lines.push("  ".repeat(depth) + text)
    }

    fn program(self, program: ast.Program) {
        for item in program.items {
            match item {
                Fn(f) {
                    self.function(0, f)
                }
                Struct(s) {
                    self.line(0, "struct {s.name} {s.name_start}:{s.name_end}")
                    for f in s.fields {
                        self.line(1, "field {f.name} {f.start}:{f.end}")
                        self.ty(2, f.ty)
                    }
                    for m in s.methods {
                        self.function(1, m)
                    }
                }
                Interface(i) {
                    self.line(0, "interface {i.name} {i.name_start}:{i.name_end}")
                    for m in i.methods {
                        self.line(1, "method {m.name} {m.name_start}:{m.name_end} fallible={flag(m.fallible)}")
                        self.params(2, m.params)
                        for ret in m.ret {
                            self.line(2, "ret")
                            self.ty(3, ret)
                        }
                    }
                }
                Enum(e) {
                    self.line(0, "enum {e.name} {e.name_start}:{e.name_end}")
                    for v in e.variants {
                        self.line(1, "variant {v.name} {v.start}:{v.end}")
                        for field in v.fields {
                            self.ty(2, field)
                        }
                    }
                }
                Global(stmt) {
                    self.line(0, "global")
                    self.stmt(1, stmt)
                }
                Check(name, body) {
                    self.line(0, "check " + quote(name))
                    self.block(1, body)
                }
                Import(path, alias, start, end) {
                    var name = "-"
                    for a in alias {
                        name = a
                    }
                    self.line(0, "import {quote(path)} {name} {start}:{end}")
                }
            }
        }
    }

    fn function(self, depth: int, f: ast.FnDecl) {
        self.line(depth, "fn {f.name} {f.name_start}:{f.name_end} self={flag(f.has_self)} fallible={flag(f.fallible)}")
        self.params(depth + 1, f.params)
        for ret in f.ret {
            self.line(depth + 1, "ret")
            self.ty(depth + 2, ret)
        }
        self.block(depth + 1, f.body)
    }

    fn params(self, depth: int, params: [ast.Param]) {
        for p in params {
            self.line(depth, "param {p.name} {p.start}:{p.end}")
            self.ty(depth + 1, p.ty)
        }
    }

    fn ty(self, depth: int, t: ast.TypeExpr) {
        var at = "{t.start}:{t.end}"
        match t.kind {
            Named(name) {
                self.line(depth, "type Named {name} {at}")
            }
            List(elem) {
                self.line(depth, "type List {at}")
                self.ty(depth + 1, elem)
            }
            Chan(elem) {
                self.line(depth, "type Chan {at}")
                self.ty(depth + 1, elem)
            }
            Weak(elem) {
                self.line(depth, "type Weak {at}")
                self.ty(depth + 1, elem)
            }
            Map(key, value) {
                self.line(depth, "type Map {at}")
                self.ty(depth + 1, key)
                self.ty(depth + 1, value)
            }
            Fn(params, ret, fallible) {
                self.line(depth, "type Fn {at} fallible={flag(fallible)}")
                for p in params {
                    self.ty(depth + 1, p)
                }
                for r in ret {
                    self.line(depth + 1, "ret")
                    self.ty(depth + 2, r)
                }
            }
        }
    }

    fn block(self, depth: int, block: ast.Block) {
        self.line(depth, "block {block.start}:{block.end}")
        for stmt in block.stmts {
            self.stmt(depth + 1, stmt)
        }
    }

    fn stmt(self, depth: int, stmt: ast.Stmt) {
        var at = "{stmt.start}:{stmt.end}"
        match stmt.kind {
            Let(name, name_start, name_end, mutable, ty, init) {
                self.line(depth, "let {name} {name_start}:{name_end} mutable={flag(mutable)} {at}")
                for t in ty {
                    self.ty(depth + 1, t)
                }
                self.expr(depth + 1, init)
            }
            Assign(target, op, value) {
                self.line(depth, "assign {variant_name(str(op))} {at}")
                self.expr(depth + 1, target)
                self.expr(depth + 1, value)
            }
            Expr(e) {
                self.line(depth, "expr {at}")
                self.expr(depth + 1, e)
            }
            If(cond, then, els) {
                self.line(depth, "if {at}")
                self.expr(depth + 1, cond)
                self.block(depth + 1, then)
                for other in els {
                    self.stmt(depth + 1, other)
                }
            }
            While(cond, body) {
                self.line(depth, "while {at}")
                self.expr(depth + 1, cond)
                self.block(depth + 1, body)
            }
            For(name, name_start, name_end, iter, body) {
                self.line(depth, "for {name} {name_start}:{name_end} {at}")
                self.expr(depth + 1, iter)
                self.block(depth + 1, body)
            }
            Return(value) {
                self.line(depth, "return {at}")
                for v in value {
                    self.expr(depth + 1, v)
                }
            }
            Break {
                self.line(depth, "break {at}")
            }
            Continue {
                self.line(depth, "continue {at}")
            }
            Fail(value) {
                self.line(depth, "fail {at}")
                self.expr(depth + 1, value)
            }
            Fork(body) {
                self.line(depth, "fork {at}")
                self.block(depth + 1, body)
            }
            Send(channel, value) {
                self.line(depth, "send {at}")
                self.expr(depth + 1, channel)
                self.expr(depth + 1, value)
            }
            Block(body) {
                self.line(depth, "blockstmt {at}")
                self.block(depth + 1, body)
            }
            Match(subject, arms, default) {
                self.line(depth, "match {at}")
                self.expr(depth + 1, subject)
                for arm in arms {
                    self.line(depth + 1, "arm")
                    for pattern in arm.patterns {
                        match pattern {
                            Literal(value) {
                                self.line(depth + 2, "pat-lit")
                                self.expr(depth + 3, value)
                            }
                            Variant(name, start, end, bindings) {
                                self.line(depth + 2, "pat-variant {name} {start}:{end}")
                                for b in bindings {
                                    self.line(depth + 3, "bind {b.text} {b.start}:{b.end}")
                                }
                            }
                        }
                    }
                    self.block(depth + 2, arm.body)
                }
                for body in default {
                    self.line(depth + 1, "default")
                    self.block(depth + 2, body)
                }
            }
        }
    }

    fn expr(self, depth: int, e: ast.Expr) {
        var at = "{e.start}:{e.end}"
        if self.ids {
            at += " #{e.id}"
        }
        match e.kind {
            Int(n) {
                self.line(depth, "Int {n} {at}")
            }
            Float(x) {
                var line = "Float {lexer.text_of(self.src, e.start, e.end)} {at}"
                if self.ids {
                    // A float may have been computed by the compiler: its bits say exactly which.
                    line += " bits={float_bits(x)}"
                }
                self.line(depth, line)
            }
            Bool(b) {
                self.line(depth, "Bool {flag(b)} {at}")
            }
            Str(parts) {
                self.line(depth, "Str {at}")
                for part in parts {
                    match part {
                        Lit(text) {
                            self.line(depth + 1, "lit " + quote(text))
                        }
                        Code(inner) {
                            self.expr(depth + 1, inner)
                        }
                    }
                }
            }
            Ident(name) {
                self.line(depth, "Ident {name} {at}")
            }
            List(items) {
                self.line(depth, "List {at}")
                for item in items {
                    self.expr(depth + 1, item)
                }
            }
            Map(entries) {
                self.line(depth, "Map {at}")
                for entry in entries {
                    self.expr(depth + 1, entry.key)
                    self.expr(depth + 1, entry.value)
                }
            }
            StructLit(name, name_start, name_end, fields) {
                self.line(depth, "StructLit {name} {name_start}:{name_end} {at}")
                for f in fields {
                    self.line(depth + 1, "init {f.name} {f.name_start}:{f.name_end}")
                    self.expr(depth + 2, f.value)
                }
            }
            Unary(op, inner) {
                self.line(depth, "Unary {variant_name(str(op))} {at}")
                self.expr(depth + 1, inner)
            }
            Binary(op, lhs, rhs) {
                self.line(depth, "Binary {variant_name(str(op))} {at}")
                self.expr(depth + 1, lhs)
                self.expr(depth + 1, rhs)
            }
            Call(callee, args) {
                self.line(depth, "Call {at}")
                self.expr(depth + 1, callee)
                for arg in args {
                    self.expr(depth + 1, arg)
                }
            }
            Field(obj, name, name_start, name_end) {
                self.line(depth, "Field {name} {name_start}:{name_end} {at}")
                self.expr(depth + 1, obj)
            }
            Index(obj, index) {
                self.line(depth, "Index {at}")
                self.expr(depth + 1, obj)
                self.expr(depth + 1, index)
            }
            Lambda(params, ret, fallible, body) {
                self.line(depth, "Lambda fallible={flag(fallible)} {at}")
                self.params(depth + 1, params)
                for r in ret {
                    self.line(depth + 1, "ret")
                    self.ty(depth + 2, r)
                }
                self.block(depth + 1, body)
            }
            Try(inner) {
                self.line(depth, "Try {at}")
                self.expr(depth + 1, inner)
            }
            Or(inner, default) {
                self.line(depth, "Or {at}")
                self.expr(depth + 1, inner)
                self.expr(depth + 1, default)
            }
            Catch(inner, name, name_start, name_end, body) {
                self.line(depth, "Catch {name} {name_start}:{name_end} {at}")
                self.expr(depth + 1, inner)
                self.block(depth + 1, body)
            }
            Recv(channel) {
                self.line(depth, "Recv {at}")
                self.expr(depth + 1, channel)
            }
            ChanNew(elem, cap) {
                self.line(depth, "ChanNew {at}")
                self.ty(depth + 1, elem)
                for c in cap {
                    self.expr(depth + 1, c)
                }
            }
            Range(lo, hi) {
                self.line(depth, "Range {at}")
                self.expr(depth + 1, lo)
                self.expr(depth + 1, hi)
            }
        }
    }
}
