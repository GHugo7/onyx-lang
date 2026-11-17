// Rewrites `match` with simpler statements, once the checker is done with it.
//
//     match shape {                   {
//         Circle(r) {                     var $m1 = shape
//             print(r)                    if __tag($m1) == 0 {
//         }                                   var r = __field($m1, 0)
//         Empty, Dot {          =>            print(r)
//             print("small")              } else if __tag($m1) == 2 || __tag($m1) == 3 {
//         }                                   print("small")
//         else {                          } else {
//             print("other")                  print("other")
//         }                               }
//     }                               }
//
// `__tag` gives the position of the variant an enum value is, and `__field`
// one of the values it carries. A `match` on numbers, strings or booleans
// compares with `==`. When there is no `else`, the checker made sure that
// the cases cover everything: the last one then needs no test.
//
// Follows src/desugar.rs: the same new nodes, with the same ids, made in the
// same order.

import "ast"
import "checker"

// Hidden variables get positions past any real source (2^50 and up), below
// 2^53 so that every target has them exactly.
const MATCH_POSITIONS = 1125899906842624

// The first id that no expression has: one past the largest one the checker
// (or a pass before) gave a type to.
fn next_free_id(an: checker.Analysis) -> int {
    var next = 0
    for id in an.types.keys() {
        if id + 1 > next {
            next = id + 1
        }
    }
    return next
}

fn desugar(program: ast.Program, an: checker.Analysis) {
    var d = Desugar{an: an, next_id: next_free_id(an), matches: 0}
    for item in program.items {
        match item {
            Fn(f) {
                d.block(f.body)
            }
            Struct(s) {
                for m in s.methods {
                    d.block(m.body)
                }
            }
            Check(_, body) {
                d.block(body)
            }
            Global(stmt) {
                d.stmt(stmt)
            }
            else {
            }
        }
    }
}

struct Desugar {
    an: checker.Analysis
    next_id: int
    matches: int

    fn node(self, kind: ast.ExprKind, ty: checker.Type, start: int, end: int) -> ast.Expr {
        var id = self.next_id
        self.next_id += 1
        self.an.types[id] = ty
        return ast.Expr{id: id, start: start, end: end, kind: kind}
    }

    // A call to one of the two helpers.
    fn helper(self, name: string, args: [ast.Expr], ty: checker.Type, start: int, end: int) -> ast.Expr {
        var callee = self.node(ast.ExprKind.Ident(name), checker.Type.Unknown, start, end)
        var call = self.node(ast.ExprKind.Call(callee, args), ty, start, end)
        self.an.calls[call.id] = checker.CallKind.Builtin(name)
        return call
    }

    fn block(self, block: ast.Block) {
        for stmt in block.stmts {
            self.stmt(stmt)
        }
    }

    fn stmt(self, stmt: ast.Stmt) {
        match stmt.kind {
            Match(subject, arms, default) {
                self.expr(subject)
                for arm in arms {
                    self.block(arm.body)
                }
                for body in default {
                    self.block(body)
                }
                stmt.kind = self.rewrite(subject, arms, default, stmt.start, stmt.end)
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

    fn rewrite(self, subject: ast.Expr, arms: [ast.MatchArm], default: [ast.Block], start: int, end: int) -> ast.StmtKind {
        var ty = checker.Type.Unknown
        if self.an.types.has(subject.id) {
            ty = self.an.types[subject.id]
        }
        var variants: [checker.Variant] = []
        match ty {
            Enum(name) {
                if self.an.enums.has(name) {
                    variants = self.an.enums[name]
                }
            }
            else {
            }
        }
        self.matches += 1
        var holder = "$m{self.matches}"
        var position = MATCH_POSITIONS + self.matches
        var keep = ast.Stmt{kind: ast.StmtKind.Let(holder, position, position, false, [], subject), start: start, end: end}

        // Built from the last case to the first, each one the `else` of the one before.
        var rest: [ast.Stmt] = []
        for body in default {
            rest = [ast.Stmt{kind: ast.StmtKind.Block(body), start: body.start, end: body.end}]
        }
        var a = arms.len() - 1
        while a >= 0 {
            var body = arms[a].body
            var cond: [ast.Expr] = []
            for pattern in arms[a].patterns {
                var value = self.node(ast.ExprKind.Ident(holder), ty, subject.start, subject.end)
                var test = value
                match pattern {
                    Literal(literal) {
                        test = self.node(ast.ExprKind.Binary(ast.BinOp.Eq, value, literal), checker.Type.Bool, literal.start, literal.end)
                    }
                    Variant(name, at_start, at_end, bindings) {
                        var index = -1
                        for i in 0..variants.len() {
                            if index < 0 && variants[i].name == name {
                                index = i
                            }
                        }
                        if index < 0 {
                            index = 0
                        }
                        // What the variant carries becomes variables at the start of the case.
                        var lets: [ast.Stmt] = []
                        for i in 0..bindings.len() {
                            var binding = bindings[i]
                            if binding.text != "_" {
                                var field_ty = checker.Type.Unknown
                                if index < variants.len() && i < variants[index].fields.len() {
                                    field_ty = variants[index].fields[i]
                                }
                                var from = self.node(ast.ExprKind.Ident(holder), ty, binding.start, binding.end)
                                var which = self.node(ast.ExprKind.Int(i), checker.Type.Int, binding.start, binding.end)
                                var init = self.helper("__field", [from, which], field_ty, binding.start, binding.end)
                                var kind = ast.StmtKind.Let(binding.text, binding.start, binding.end, true, [], init)
                                lets.push(ast.Stmt{kind: kind, start: binding.start, end: binding.end})
                            }
                        }
                        if lets.len() > 0 {
                            for s in body.stmts {
                                lets.push(s)
                            }
                            body.stmts = lets
                        }
                        var tag = self.helper("__tag", [value], checker.Type.Int, at_start, at_end)
                        var number = self.node(ast.ExprKind.Int(index), checker.Type.Int, at_start, at_end)
                        test = self.node(ast.ExprKind.Binary(ast.BinOp.Eq, tag, number), checker.Type.Bool, at_start, at_end)
                    }
                }
                if cond.len() == 0 {
                    cond = [test]
                } else {
                    cond = [self.node(ast.ExprKind.Binary(ast.BinOp.Or, cond[0], test), checker.Type.Bool, test.start, test.end)]
                }
            }
            if rest.len() == 0 || cond.len() == 0 {
                // The last case of a `match` without `else`: nothing else is possible.
                rest = [ast.Stmt{kind: ast.StmtKind.Block(body), start: body.start, end: body.end}]
            } else {
                rest = [ast.Stmt{kind: ast.StmtKind.If(cond[0], body, rest), start: body.start, end: body.end}]
            }
            a -= 1
        }
        var stmts = [keep]
        for s in rest {
            stmts.push(s)
        }
        return ast.StmtKind.Block(ast.Block{stmts: stmts, start: start, end: end})
    }

    // Only looks for the blocks inside expressions: lambdas and `catch`.
    fn expr(self, e: ast.Expr) {
        match e.kind {
            Lambda(_, _, _, body) {
                self.block(body)
            }
            Catch(inner, _, _, _, body) {
                self.expr(inner)
                self.block(body)
            }
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
            Or(inner, default) {
                self.expr(inner)
                self.expr(default)
            }
            ChanNew(_, cap) {
                for c in cap {
                    self.expr(c)
                }
            }
            else {
            }
        }
    }
}
