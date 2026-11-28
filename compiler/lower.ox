// Prepares error handling for the native code generator.
//
// When a call followed by `?` fails, the function returns on the spot. If
// that happens in the middle of a larger expression, the values already
// computed for it (the other arguments of a call, the left side of a `+`...)
// would be left behind, never released. This pass rewrites such statements
// so that every `?` sits at the root of a statement, where nothing is
// pending: whatever is computed before it goes into temporary variables,
// in the original order.
//
//     var x = f(a(), b()?)        var $t1 = a()
//                           =>    var $t2 = b()?
//                                 var x = f($t1, $t2)
//
// `catch` blocks, which may also leave the function, get the same treatment
// when they are used in an assignment to a field or an element.
//
// Follows src/native/lower.rs.

import "ast"
import "checker"
import "desugar"

// Temporary variables get positions past any real source (3 * 2^50 and up),
// so that they never share a key with a variable of the program.
const TEMP_POSITIONS = 3377699720527872

// For the JVM target, `or` also goes to the root of a statement: when the
// JVM catches an exception, it empties the operand stack, and what was
// computed before the `or` would be lost.
var or_leaves = false

fn lower(program: ast.Program, an: checker.Analysis) {
    lower_for(program, an, false)
}

fn lower_for(program: ast.Program, an: checker.Analysis, jvm: bool) {
    or_leaves = jvm
    var globals: map<string, bool> = {}
    for item in program.items {
        match item {
            Global(stmt) {
                match stmt.kind {
                    Let(name, _, _, _, _, _) {
                        globals[name] = true
                    }
                    else {
                    }
                }
            }
            else {
            }
        }
    }
    var l = Lower{an: an, globals: globals, next_id: desugar.next_free_id(an), temps: 0}
    for item in program.items {
        match item {
            Fn(f) {
                l.block(f.body)
            }
            Struct(s) {
                for m in s.methods {
                    l.block(m.body)
                }
            }
            Check(_, body) {
                l.block(body)
            }
            // A top-level variable may hold a lambda.
            Global(stmt) {
                match stmt.kind {
                    Let(_, _, _, _, _, init) {
                        if jvm {
                            // Its value is computed like a statement's: what it
                            // needs first goes before it, and the variable
                            // becomes the last statement of a block.
                            var copy = ast.Stmt{kind: stmt.kind, start: stmt.start, end: stmt.end}
                            var out: [ast.Stmt] = []
                            l.stmt(copy, out)
                            if out.len() > 1 {
                                stmt.kind = ast.StmtKind.Block(ast.Block{stmts: out, start: stmt.start, end: stmt.end})
                            }
                        } else {
                            l.lambdas(init)
                        }
                    }
                    else {
                    }
                }
            }
            else {
            }
        }
    }
}

// Does evaluating `e` reach a `?` (lambda bodies are separate functions)?
fn contains_try(e: ast.Expr) -> bool {
    match e.kind {
        Try(_) {
            return true
        }
        Str(parts) {
            for part in parts {
                match part {
                    Code(inner) {
                        if contains_try(inner) {
                            return true
                        }
                    }
                    else {
                    }
                }
            }
            return false
        }
        List(items) {
            for item in items {
                if contains_try(item) {
                    return true
                }
            }
            return false
        }
        Map(entries) {
            for entry in entries {
                if contains_try(entry.key) || contains_try(entry.value) {
                    return true
                }
            }
            return false
        }
        StructLit(_, _, _, fields) {
            for f in fields {
                if contains_try(f.value) {
                    return true
                }
            }
            return false
        }
        Unary(_, inner) {
            return contains_try(inner)
        }
        Recv(inner) {
            return contains_try(inner)
        }
        Field(obj, _, _, _) {
            return contains_try(obj)
        }
        Binary(_, lhs, rhs) {
            return contains_try(lhs) || contains_try(rhs)
        }
        Index(obj, index) {
            return contains_try(obj) || contains_try(index)
        }
        Range(lo, hi) {
            return contains_try(lo) || contains_try(hi)
        }
        Call(callee, args) {
            if contains_try(callee) {
                return true
            }
            for arg in args {
                if contains_try(arg) {
                    return true
                }
            }
            return false
        }
        Or(inner, default) {
            return or_leaves || contains_try(inner) || contains_try(default)
        }
        // The block of a `catch` is made of statements, lowered on their own.
        Catch(inner, _, _, _, _) {
            return contains_try(inner)
        }
        ChanNew(_, cap) {
            for c in cap {
                if contains_try(c) {
                    return true
                }
            }
            return false
        }
        else {
            return false
        }
    }
}

// Lists, maps, structs and interfaces: values that a later operand could
// still change.
fn is_object(t: checker.Type) -> bool {
    match t {
        List(_) {
            return true
        }
        Map(_, _) {
            return true
        }
        Struct(_) {
            return true
        }
        Interface(_) {
            return true
        }
        else {
            return false
        }
    }
}

// The position of the last element of `children` that reaches a `?`, or -1.
fn last_try(children: [ast.Expr]) -> int {
    var last = -1
    for i in 0..children.len() {
        if contains_try(children[i]) {
            last = i
        }
    }
    return last
}

struct Lower {
    an: checker.Analysis
    globals: map<string, bool>
    next_id: int
    temps: int

    fn ty(self, e: ast.Expr) -> checker.Type {
        if self.an.types.has(e.id) {
            return self.an.types[e.id]
        }
        return checker.Type.Unknown
    }

    // A new expression node of a known type.
    fn node(self, kind: ast.ExprKind, ty: checker.Type, start: int, end: int) -> ast.Expr {
        var id = self.next_id
        self.next_id += 1
        self.an.types[id] = ty
        return ast.Expr{id: id, start: start, end: end, kind: kind}
    }

    // A literal or a local variable can be read later without any difference.
    fn is_stable(self, e: ast.Expr) -> bool {
        match e.kind {
            Int(_) {
                return true
            }
            Float(_) {
                return true
            }
            Bool(_) {
                return true
            }
            Str(parts) {
                for part in parts {
                    match part {
                        Code(_) {
                            return false
                        }
                        else {
                        }
                    }
                }
                return true
            }
            // A name that no top-level variable has can only be a local one.
            Ident(name) {
                return !self.globals.has(name)
            }
            else {
                return false
            }
        }
    }

    // Emits `var $tN = value` and returns a reference to that variable.
    fn temp(self, value: ast.Expr, out: [ast.Stmt]) -> ast.Expr {
        var ty = self.ty(value)
        self.temps += 1
        var name = "$t{self.temps}"
        var position = TEMP_POSITIONS + self.temps
        out.push(ast.Stmt{kind: ast.StmtKind.Let(name, position, position, true, [], value), start: value.start, end: value.end})
        return self.node(ast.ExprKind.Ident(name), ty, value.start, value.end)
    }

    // Another reference to the variable that `e` names.
    fn again(self, e: ast.Expr) -> ast.Expr {
        return self.node(e.kind, self.ty(e), e.start, e.end)
    }

    // Moves `e` into a temporary variable unless reading it later is the same.
    fn settle(self, e: ast.Expr, out: [ast.Stmt]) {
        if !self.is_stable(e) {
            var value = ast.copy_of(e)
            ast.overwrite(e, self.temp(value, out))
        }
    }

    // The operands of an expression are evaluated one after the other. Those
    // up to the last one that contains a `?` are computed beforehand, in
    // order, so that nothing is pending when the `?` is reached.
    fn operands(self, children: [ast.Expr], out: [ast.Stmt]) {
        var count = last_try(children) + 1
        for i in 0..count {
            self.expr(children[i], out)
            self.settle(children[i], out)
        }
    }

    // Like `operands`, for values that are turned into text (the arguments
    // of `print`, the parts of an interpolated string). A list or a struct
    // is shown as it is at that moment: what is kept for later is its text,
    // not the object, which a later operand could still change.
    fn shown(self, children: [ast.Expr], out: [ast.Stmt]) {
        var count = last_try(children) + 1
        for i in 0..count {
            var child = children[i]
            self.expr(child, out)
            self.settle(child, out)
            if is_object(self.ty(child)) {
                var value = ast.copy_of(child)
                var callee = self.node(ast.ExprKind.Ident("str"), checker.Type.Unknown, child.start, child.end)
                var text = self.node(ast.ExprKind.Call(callee, [value]), checker.Type.Str, child.start, child.end)
                self.an.calls[text.id] = checker.CallKind.Builtin("str")
                ast.overwrite(child, self.temp(text, out))
            }
        }
    }

    // The receiver and the arguments of a call.
    fn call_operands(self, call: ast.Expr, out: [ast.Stmt]) {
        if self.an.calls.has(call.id) {
            match self.an.calls[call.id] {
                Builtin(name) {
                    if name == "print" || name == "eprint" || name == "str" {
                        match call.kind {
                            Call(_, args) {
                                self.shown(args, out)
                            }
                            else {
                            }
                        }
                        return
                    }
                }
                else {
                }
            }
        }
        if self.an.variants.has(call.id) {
            // `Shape.Circle(...)`: `Shape` is not a value, only the arguments are.
            match call.kind {
                Call(_, args) {
                    self.operands(args, out)
                }
                else {
                }
            }
            return
        }
        match call.kind {
            Call(callee, args) {
                var children: [ast.Expr] = []
                match callee.kind {
                    Field(obj, _, _, _) {
                        children.push(obj)
                    }
                    Ident(_) {
                    }
                    else {
                        children.push(callee)
                    }
                }
                for arg in args {
                    children.push(arg)
                }
                self.operands(children, out)
            }
            else {
            }
        }
    }

    // Rewrites `e` so that it contains no `?`, except possibly at its very
    // root (a call followed by `?` whose operands have none).
    fn expr(self, e: ast.Expr, out: [ast.Stmt]) {
        match e.kind {
            Catch(inner, _, _, _, body) {
                self.call_operands(inner, out)
                self.block(body)
                return
            }
            else {
            }
        }
        if !contains_try(e) {
            return
        }
        var start = e.start
        var end = e.end
        var ty = self.ty(e)
        match e.kind {
            Try(call) {
                self.call_operands(call, out)
            }
            Binary(op, lhs, rhs) {
                if (op == ast.BinOp.And || op == ast.BinOp.Or) && contains_try(rhs) {
                    // The right side only runs for some values of the left side:
                    //     var $t = lhs
                    //     if $t { $t = rhs }          (`if !$t` for `||`)
                    self.expr(lhs, out)
                    var result = self.temp(lhs, out)
                    var then: [ast.Stmt] = []
                    self.expr(rhs, then)
                    var target = self.again(result)
                    then.push(ast.Stmt{kind: ast.StmtKind.Assign(target, ast.AssignOp.Set, rhs), start: start, end: end})
                    var cond = self.again(result)
                    if op == ast.BinOp.Or {
                        cond = self.node(ast.ExprKind.Unary(ast.UnOp.Not, cond), checker.Type.Bool, start, end)
                    }
                    var body = ast.Block{stmts: then, start: start, end: end}
                    out.push(ast.Stmt{kind: ast.StmtKind.If(cond, body, []), start: start, end: end})
                    ast.overwrite(e, result)
                } else {
                    self.operands([lhs, rhs], out)
                }
            }
            Or(inner, default) {
                if contains_try(default) {
                    // The default only runs when the call fails:
                    //     var $t = call catch $e { ...; default }
                    self.call_operands(inner, out)
                    var body: [ast.Stmt] = []
                    self.expr(default, body)
                    body.push(ast.Stmt{kind: ast.StmtKind.Expr(default), start: start, end: end})
                    self.temps += 1
                    var position = TEMP_POSITIONS + self.temps
                    var block = ast.Block{stmts: body, start: start, end: end}
                    var caught = self.node(ast.ExprKind.Catch(inner, "$e{self.temps}", position, position, block), ty, start, end)
                    self.an.catch_values[caught.id] = true
                    ast.overwrite(e, self.temp(caught, out))
                } else {
                    self.call_operands(inner, out)
                }
            }
            Str(parts) {
                var children: [ast.Expr] = []
                for part in parts {
                    match part {
                        Code(inner) {
                            children.push(inner)
                        }
                        else {
                        }
                    }
                }
                self.shown(children, out)
            }
            List(items) {
                self.operands(items, out)
            }
            Map(entries) {
                var children: [ast.Expr] = []
                for entry in entries {
                    children.push(entry.key)
                    children.push(entry.value)
                }
                self.operands(children, out)
            }
            StructLit(name, _, _, fields) {
                // Fields are evaluated in the order of the struct's declaration.
                var order: [string] = []
                if self.an.structs.has(name) {
                    for f in self.an.structs[name].fields {
                        order.push(f.name)
                    }
                }
                var keys: [int] = []
                for f in fields {
                    keys.push(order.index_of(f.name))
                }
                var children: [ast.Expr] = []
                for k in -1..order.len() {
                    for i in 0..fields.len() {
                        if keys[i] == k {
                            children.push(fields[i].value)
                        }
                    }
                }
                self.operands(children, out)
            }
            Unary(_, inner) {
                self.operands([inner], out)
            }
            Recv(inner) {
                self.operands([inner], out)
            }
            Field(obj, _, _, _) {
                self.operands([obj], out)
            }
            Index(obj, index) {
                self.operands([obj, index], out)
            }
            Range(lo, hi) {
                self.operands([lo, hi], out)
            }
            Call(_, _) {
                self.call_operands(e, out)
            }
            ChanNew(_, cap) {
                self.operands(cap, out)
            }
            else {
            }
        }
    }

    fn block(self, block: ast.Block) {
        var out: [ast.Stmt] = []
        for stmt in block.stmts {
            self.stmt(stmt, out)
        }
        block.stmts = out
    }

    // Lambdas are functions of their own: their bodies are lowered as such.
    fn lambdas(self, e: ast.Expr) {
        match e.kind {
            Lambda(_, _, _, body) {
                self.block(body)
            }
            Str(parts) {
                for part in parts {
                    match part {
                        Code(inner) {
                            self.lambdas(inner)
                        }
                        else {
                        }
                    }
                }
            }
            List(items) {
                for item in items {
                    self.lambdas(item)
                }
            }
            Map(entries) {
                for entry in entries {
                    self.lambdas(entry.key)
                    self.lambdas(entry.value)
                }
            }
            StructLit(_, _, _, fields) {
                for f in fields {
                    self.lambdas(f.value)
                }
            }
            Unary(_, inner) {
                self.lambdas(inner)
            }
            Try(inner) {
                self.lambdas(inner)
            }
            Recv(inner) {
                self.lambdas(inner)
            }
            Field(obj, _, _, _) {
                self.lambdas(obj)
            }
            Binary(_, lhs, rhs) {
                self.lambdas(lhs)
                self.lambdas(rhs)
            }
            Index(obj, index) {
                self.lambdas(obj)
                self.lambdas(index)
            }
            Range(lo, hi) {
                self.lambdas(lo)
                self.lambdas(hi)
            }
            Call(callee, args) {
                self.lambdas(callee)
                for arg in args {
                    self.lambdas(arg)
                }
            }
            Or(inner, default) {
                self.lambdas(inner)
                self.lambdas(default)
            }
            // The block of a `catch` is lowered with the statement it belongs to.
            Catch(inner, _, _, _, _) {
                self.lambdas(inner)
            }
            ChanNew(_, cap) {
                for c in cap {
                    self.lambdas(c)
                }
            }
            else {
            }
        }
    }

    // Lowers one statement into `out` (what it needs first, then itself).
    fn stmt(self, stmt: ast.Stmt, out: [ast.Stmt]) {
        var start = stmt.start
        var end = stmt.end
        match stmt.kind {
            Let(_, _, _, _, _, init) {
                self.lambdas(init)
            }
            Expr(e) {
                self.lambdas(e)
            }
            Fail(e) {
                self.lambdas(e)
            }
            Return(value) {
                for e in value {
                    self.lambdas(e)
                }
            }
            Assign(target, _, value) {
                self.lambdas(target)
                self.lambdas(value)
            }
            If(cond, _, _) {
                self.lambdas(cond)
            }
            While(cond, _) {
                self.lambdas(cond)
            }
            For(_, _, _, iter, _) {
                self.lambdas(iter)
            }
            Send(channel, value) {
                self.lambdas(channel)
                self.lambdas(value)
            }
            else {
            }
        }
        match stmt.kind {
            Match(_, _, _) {
                panic("`match` is rewritten by desugar before this pass")
            }
            Let(_, _, _, _, _, init) {
                self.expr(init, out)
            }
            Expr(e) {
                self.expr(e, out)
            }
            Fail(e) {
                self.expr(e, out)
            }
            Return(value) {
                for e in value {
                    self.expr(e, out)
                }
            }
            Break, Continue {
            }
            Assign(target, op, value) {
                self.assign(stmt, target, op, value, out)
            }
            If(cond, then, els) {
                self.expr(cond, out)
                self.block(then)
                for other in els {
                    // What an `else if` needs first must only run when it is reached.
                    var inner: [ast.Stmt] = []
                    self.stmt(other, inner)
                    var lowered = inner[0]
                    if inner.len() != 1 {
                        lowered = ast.Stmt{kind: ast.StmtKind.Block(ast.Block{stmts: inner, start: start, end: end}), start: start, end: end}
                    }
                    stmt.kind = ast.StmtKind.If(cond, then, [lowered])
                }
            }
            While(cond, body) {
                self.block(body)
                var before: [ast.Stmt] = []
                self.expr(cond, before)
                if before.len() > 0 {
                    // The condition needs statements on every turn:
                    //     while true { ...; var $c = cond; if !$c { break }; body }
                    var truth = self.node(ast.ExprKind.Bool(true), checker.Type.Bool, start, end)
                    var test = ast.copy_of(cond)
                    ast.overwrite(cond, truth)
                    var passed = self.temp(test, before)
                    var stop = self.node(ast.ExprKind.Unary(ast.UnOp.Not, passed), checker.Type.Bool, start, end)
                    var leave = ast.Stmt{kind: ast.StmtKind.Break, start: start, end: end}
                    var then = ast.Block{stmts: [leave], start: start, end: end}
                    before.push(ast.Stmt{kind: ast.StmtKind.If(stop, then, []), start: start, end: end})
                    for s in body.stmts {
                        before.push(s)
                    }
                    body.stmts = before
                }
            }
            For(_, _, _, iter, body) {
                self.expr(iter, out)
                self.block(body)
            }
            Fork(body) {
                self.block(body)
            }
            Block(body) {
                self.block(body)
            }
            Send(channel, value) {
                self.expr(channel, out)
                self.expr(value, out)
            }
        }
        out.push(stmt)
    }

    fn assign(self, stmt: ast.Stmt, target: ast.Expr, op: ast.AssignOp, value: ast.Expr, out: [ast.Stmt]) {
        var start = stmt.start
        var end = stmt.end
        var is_catch = false
        match value.kind {
            Catch(_, _, _, _, _) {
                is_catch = true
            }
            else {
            }
        }
        var is_ident = false
        match target.kind {
            Ident(_) {
                is_ident = true
            }
            else {
            }
        }
        var leaves = contains_try(target) || contains_try(value) || is_catch
        var direct = is_ident && op == ast.AssignOp.Set
        if !leaves && op != ast.AssignOp.Set && self.ty(target) == checker.Type.Float {
            // The code generator updates integers in place; a float is
            // computed and then stored: `x += v` becomes `x = x + v`.
            match target.kind {
                Field(obj, _, _, _) {
                    self.settle(obj, out)
                }
                Index(obj, index) {
                    self.settle(obj, out)
                    self.settle(index, out)
                }
                else {
                }
            }
            var current = self.reader(target)
            var amount = ast.copy_of(value)
            ast.overwrite(value, self.node(ast.ExprKind.Binary(binop(op), current, amount), checker.Type.Float, start, end))
            stmt.kind = ast.StmtKind.Assign(target, ast.AssignOp.Set, value)
            return
        }
        if !leaves || direct {
            self.expr(value, out)
            return
        }
        // The object and the position are computed first, then the value,
        // and only then is anything stored.
        match target.kind {
            Field(obj, _, _, _) {
                self.expr(obj, out)
                self.settle(obj, out)
            }
            Index(obj, index) {
                self.expr(obj, out)
                self.settle(obj, out)
                self.expr(index, out)
                self.settle(index, out)
            }
            else {
            }
        }
        // `target op= value` reads the target before computing the value.
        var current: [ast.Expr] = []
        if op != ast.AssignOp.Set {
            var read = self.reader(target)
            current = [self.temp(read, out)]
        }
        self.expr(value, out)
        var computed = ast.copy_of(value)
        var result = self.temp(computed, out)
        for c in current {
            result = self.node(ast.ExprKind.Binary(binop(op), c, result), self.ty(target), start, end)
        }
        ast.overwrite(value, result)
        stmt.kind = ast.StmtKind.Assign(target, ast.AssignOp.Set, value)
    }

    // An expression that reads what the assignment target `target` holds.
    fn reader(self, target: ast.Expr) -> ast.Expr {
        var ty = self.ty(target)
        var kind = target.kind
        match target.kind {
            Field(obj, name, name_start, name_end) {
                kind = ast.ExprKind.Field(self.again(obj), name, name_start, name_end)
            }
            Index(obj, index) {
                var o = self.again(obj)
                var i = self.again(index)
                kind = ast.ExprKind.Index(o, i)
            }
            else {
            }
        }
        return self.node(kind, ty, target.start, target.end)
    }
}

// The operation of a compound assignment (`+=` is `+`).
fn binop(op: ast.AssignOp) -> ast.BinOp {
    match op {
        Add {
            return ast.BinOp.Add
        }
        Sub {
            return ast.BinOp.Sub
        }
        Mul {
            return ast.BinOp.Mul
        }
        else {
            return ast.BinOp.Div
        }
    }
}
