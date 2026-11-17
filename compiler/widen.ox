// Makes the conversions from `int` to `float` explicit.
//
// Onyx accepts an int wherever a float is expected: `var x: float = 3`,
// `sqrt(2)`, `2 * 1.5`. Natively an int and a float with the same value are
// different bits, so the int must be converted where it is used as a float.
// The checker noted every such expression (`Analysis.widened`); this pass
// rewrites each one:
//
//     var x: float = 3            var x: float = 3.0
//     sqrt(n)               =>    sqrt(float(n))
//     total += count              total += float(count)
//
// Follows src/native/widen.rs.

import "ast"
import "checker"
import "desugar"

fn widen(program: ast.Program, an: checker.Analysis) {
    if an.widened.len() == 0 {
        return
    }
    var w = Widen{an: an, next_id: desugar.next_free_id(an)}
    for item in program.items {
        match item {
            Fn(f) {
                w.block(f.body)
            }
            Struct(s) {
                for m in s.methods {
                    w.block(m.body)
                }
            }
            Global(stmt) {
                w.stmt(stmt)
            }
            Check(_, body) {
                w.block(body)
            }
            else {
            }
        }
    }
}

struct Widen {
    an: checker.Analysis
    next_id: int

    fn fresh(self, ty: checker.Type) -> int {
        var id = self.next_id
        self.next_id += 1
        self.an.types[id] = ty
        return id
    }

    fn block(self, block: ast.Block) {
        for stmt in block.stmts {
            self.stmt(stmt)
        }
    }

    fn stmt(self, stmt: ast.Stmt) {
        match stmt.kind {
            Match(_, _, _) {
                panic("`match` is rewritten by desugar before this pass")
            }
            Let(_, _, _, _, _, init) {
                self.expr(init)
            }
            Expr(e) {
                self.expr(e)
            }
            Fail(e) {
                self.expr(e)
            }
            Return(value) {
                for e in value {
                    self.expr(e)
                }
            }
            Break, Continue {
            }
            Assign(target, _, value) {
                self.expr(target)
                self.expr(value)
            }
            If(cond, then, els) {
                self.expr(cond)
                self.block(then)
                for other in els {
                    self.stmt(other)
                }
            }
            While(cond, body) {
                self.expr(cond)
                self.block(body)
            }
            For(_, _, _, iter, body) {
                self.expr(iter)
                self.block(body)
            }
            Fork(body) {
                self.block(body)
            }
            Block(body) {
                self.block(body)
            }
            Send(channel, value) {
                self.expr(channel)
                self.expr(value)
            }
        }
    }

    fn expr(self, e: ast.Expr) {
        match e.kind {
            Str(parts) {
                for part in parts {
                    match part {
                        Code(inner) {
                            self.expr(inner)
                        }
                        else {
                        }
                    }
                }
            }
            List(items) {
                for item in items {
                    self.expr(item)
                }
            }
            Map(entries) {
                for entry in entries {
                    self.expr(entry.key)
                    self.expr(entry.value)
                }
            }
            StructLit(_, _, _, fields) {
                for f in fields {
                    self.expr(f.value)
                }
            }
            Unary(_, inner) {
                self.expr(inner)
            }
            Try(inner) {
                self.expr(inner)
            }
            Recv(inner) {
                self.expr(inner)
            }
            Field(obj, _, _, _) {
                self.expr(obj)
            }
            Binary(_, lhs, rhs) {
                self.expr(lhs)
                self.expr(rhs)
            }
            Index(obj, index) {
                self.expr(obj)
                self.expr(index)
            }
            Range(lo, hi) {
                self.expr(lo)
                self.expr(hi)
            }
            Call(callee, args) {
                self.expr(callee)
                for arg in args {
                    self.expr(arg)
                }
            }
            Lambda(_, _, _, body) {
                self.block(body)
            }
            Or(inner, default) {
                self.expr(inner)
                self.expr(default)
            }
            Catch(inner, _, _, _, body) {
                self.expr(inner)
                self.block(body)
            }
            ChanNew(_, cap) {
                for c in cap {
                    self.expr(c)
                }
            }
            else {
            }
        }
        if !self.an.widened.has(e.id) {
            return
        }
        match e.kind {
            Int(n) {
                // A literal changes on the spot.
                e.kind = ast.ExprKind.Float(float(n))
                self.an.types[e.id] = checker.Type.Float
                return
            }
            else {
            }
        }
        // Anything else is converted when the program runs: `float(e)`.
        var callee = ast.Expr{id: self.fresh(checker.Type.Unknown), start: e.start, end: e.end, kind: ast.ExprKind.Ident("float")}
        var id = self.fresh(checker.Type.Float)
        self.an.calls[id] = checker.CallKind.Builtin("float")
        var inner = ast.Expr{id: e.id, start: e.start, end: e.end, kind: e.kind}
        e.id = id
        e.kind = ast.ExprKind.Call(callee, [inner])
    }
}
