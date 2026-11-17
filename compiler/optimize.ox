// Compile-time simplification, shared by every backend.
//
// Runs after type checking, on a program known to be correct, and never
// changes what the program does:
//   - constant expressions are computed (`2 * 60` becomes `120`);
//   - `const` values that are plain literals are copied into their uses;
//   - literal pieces of string interpolations are merged;
//   - branches that can never run, and statements after a `return`,
//     `break`, `continue` or `fail`, are removed.
//
// Nodes keep their ids, so the checker's side tables stay valid. A node is
// only ever replaced by a literal or by one of its own children.
//
// Follows src/optimize.rs, so that both compilers compute the same values.

import "ast"

// 2^53 - 1. Beyond it the JavaScript target is not exact, so integers out of
// that range are left for the program to compute on its target.
const MAX_SAFE = 9007199254740991

// String constants up to this size (in bytes) are copied into their uses.
const MAX_INLINE_STR = 64

enum Lit {
    Int(int)
    Float(float)
    Bool(bool)
    Str(string)
}

fn into_kind(value: Lit) -> ast.ExprKind {
    match value {
        Int(n) {
            return ast.ExprKind.Int(n)
        }
        Float(x) {
            return ast.ExprKind.Float(x)
        }
        Bool(b) {
            return ast.ExprKind.Bool(b)
        }
        Str(s) {
            return ast.ExprKind.Str([ast.StrPart.Lit(s)])
        }
    }
}

fn is_safe(n: int) -> bool {
    return n >= -MAX_SAFE && n <= MAX_SAFE
}

fn byte_len(s: string) -> int {
    return bytes(s).len()
}

fn is_ascii(s: string) -> bool {
    for b in bytes(s) {
        if b >= 128 {
            return false
        }
    }
    return true
}

// Neither infinite nor NaN: the exponent bits are not all ones.
fn is_finite(x: float) -> bool {
    return (float_bits(x) >> 52) & 2047 != 2047
}

// The text of a string literal without interpolation (no element: it is
// something else).
fn plain_str(e: ast.Expr) -> [string] {
    match e.kind {
        Str(parts) {
            if parts.len() == 0 {
                return [""]
            }
            if parts.len() == 1 {
                match parts[0] {
                    Lit(s) {
                        return [s]
                    }
                    else {
                    }
                }
            }
            return []
        }
        else {
            return []
        }
    }
}

// The value a constant declared as `const name: ty = init` stands for.
fn constant(init: ast.Expr, ty: [ast.TypeExpr]) -> [Lit] {
    var is_float = false
    for t in ty {
        match t.kind {
            Named(n) {
                is_float = n == "float"
            }
            else {
            }
        }
    }
    match init.kind {
        // `const HALF: float = 1` is the float 1.0 wherever it is used.
        Int(n) {
            if is_float {
                return [Lit.Float(float(n))]
            }
            return [Lit.Int(n)]
        }
        Float(x) {
            return [Lit.Float(x)]
        }
        Bool(b) {
            return [Lit.Bool(b)]
        }
        else {
            for s in plain_str(init) {
                if byte_len(s) <= MAX_INLINE_STR {
                    return [Lit.Str(s)]
                }
            }
            return []
        }
    }
}

fn is_propagated_const(stmt: ast.Stmt) -> bool {
    match stmt.kind {
        Let(_, _, _, mutable, ty, init) {
            return !mutable && constant(init, ty).len() > 0
        }
        else {
            return false
        }
    }
}

fn leaves(stmt: ast.Stmt) -> bool {
    match stmt.kind {
        Return(_) {
            return true
        }
        Break, Continue {
            return true
        }
        Fail(_) {
            return true
        }
        else {
            return false
        }
    }
}

fn optimize(program: ast.Program) {
    var top: map<string, [Lit]> = {}
    var f = Folder{scopes: [top]}

    // Top-level variables first: they are visible in every function.
    for item in program.items {
        match item {
            Global(stmt) {
                match stmt.kind {
                    Let(name, _, _, mutable, ty, init) {
                        f.expr(init)
                        var value: [Lit] = []
                        if !mutable {
                            value = constant(init, ty)
                        }
                        top[name] = value
                    }
                    else {
                    }
                }
            }
            else {
            }
        }
    }
    for item in program.items {
        match item {
            Fn(function) {
                f.function(function)
            }
            Struct(s) {
                for method in s.methods {
                    f.function(method)
                }
            }
            Check(_, body) {
                f.block(body)
            }
            else {
            }
        }
    }
    // Constants that were copied into all their uses are not needed any more.
    var kept: [ast.Item] = []
    for item in program.items {
        var dropped = false
        match item {
            Global(stmt) {
                dropped = is_propagated_const(stmt)
            }
            else {
            }
        }
        if !dropped {
            kept.push(item)
        }
    }
    program.items = kept
}

// What a node should become.
enum Simplified {
    Same
    Kind(ast.ExprKind)
    Lhs
    Rhs
}

struct Folder {
    // Names in scope. One element for a constant with a known value, none
    // for anything else (which hides an outer constant of the same name).
    scopes: [map<string, [Lit]>]

    fn lookup(self, name: string) -> [Lit] {
        var i = self.scopes.len() - 1
        while i >= 0 {
            if self.scopes[i].has(name) {
                return self.scopes[i][name]
            }
            i -= 1
        }
        return []
    }

    fn declare(self, name: string, value: [Lit]) {
        var scope = self.scopes[self.scopes.len() - 1]
        scope[name] = value
    }

    fn push(self) {
        var scope: map<string, [Lit]> = {}
        self.scopes.push(scope)
    }

    fn pop(self) {
        self.scopes.remove(self.scopes.len() - 1)
    }

    fn function(self, f: ast.FnDecl) {
        self.push()
        if f.has_self {
            self.declare("self", [])
        }
        for p in f.params {
            self.declare(p.name, [])
        }
        self.stmts(f.body)
        self.pop()
    }

    fn block(self, block: ast.Block) {
        self.push()
        self.stmts(block)
        self.pop()
    }

    fn stmts(self, block: ast.Block) {
        var kept: [ast.Stmt] = []
        for stmt in block.stmts {
            if self.stmt(stmt) {
                kept.push(stmt)
                if leaves(stmt) {
                    // Nothing after this can run.
                    break
                }
            }
        }
        block.stmts = kept
    }

    // Simplifies a statement. Returns false when it has no effect left and
    // should be dropped.
    fn stmt(self, stmt: ast.Stmt) -> bool {
        match stmt.kind {
            Match(_, _, _) {
                panic("`match` is rewritten by desugar before this pass")
            }
            Let(name, _, _, mutable, ty, init) {
                self.expr(init)
                var value: [Lit] = []
                if !mutable {
                    value = constant(init, ty)
                }
                self.declare(name, value)
                return value.len() == 0
            }
            Assign(target, _, value) {
                match target.kind {
                    Ident(_) {
                    }
                    Field(obj, _, _, _) {
                        self.expr(obj)
                    }
                    Index(obj, index) {
                        self.expr(obj)
                        self.expr(index)
                    }
                    else {
                        self.expr(target)
                    }
                }
                self.expr(value)
            }
            Expr(e) {
                self.expr(e)
            }
            Fail(e) {
                self.expr(e)
            }
            If(cond, then, els) {
                self.expr(cond)
                self.block(then)
                var other: [ast.Stmt] = []
                for s in els {
                    if self.stmt(s) {
                        other = [s]
                    }
                }
                match cond.kind {
                    Bool(b) {
                        if b {
                            stmt.kind = ast.StmtKind.Block(then)
                            return true
                        }
                        for s in other {
                            stmt.kind = s.kind
                            return true
                        }
                        return false
                    }
                    else {
                    }
                }
                if other.len() != els.len() {
                    stmt.kind = ast.StmtKind.If(cond, then, other)
                }
            }
            While(cond, body) {
                self.expr(cond)
                self.block(body)
                match cond.kind {
                    Bool(b) {
                        if !b {
                            return false
                        }
                    }
                    else {
                    }
                }
            }
            For(name, _, _, iter, body) {
                self.expr(iter)
                self.push()
                self.declare(name, [])
                self.block(body)
                self.pop()
            }
            Return(value) {
                for e in value {
                    self.expr(e)
                }
            }
            Break, Continue {
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
        return true
    }

    fn expr(self, e: ast.Expr) {
        match e.kind {
            Int(_) {
                return
            }
            Float(_) {
                return
            }
            Bool(_) {
                return
            }
            Ident(name) {
                for value in self.lookup(name) {
                    e.kind = into_kind(value)
                }
                return
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
                e.kind = ast.ExprKind.Str(merge_parts(parts))
                return
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
                for field in fields {
                    self.expr(field.value)
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
            Binary(_, lhs, rhs) {
                self.expr(lhs)
                self.expr(rhs)
            }
            Call(callee, args) {
                self.expr(callee)
                for arg in args {
                    self.expr(arg)
                }
            }
            Field(obj, _, _, _) {
                self.expr(obj)
            }
            Index(obj, index) {
                self.expr(obj)
                self.expr(index)
            }
            Lambda(params, _, _, body) {
                self.push()
                for p in params {
                    self.declare(p.name, [])
                }
                self.stmts(body)
                self.pop()
            }
            Or(inner, default) {
                self.expr(inner)
                self.expr(default)
            }
            Catch(inner, name, _, _, body) {
                self.expr(inner)
                self.push()
                self.declare(name, [])
                self.stmts(body)
                self.pop()
            }
            ChanNew(_, cap) {
                for c in cap {
                    self.expr(c)
                }
            }
            Range(lo, hi) {
                self.expr(lo)
                self.expr(hi)
            }
        }

        match simplify(e) {
            Same {
            }
            Kind(kind) {
                e.kind = kind
            }
            Lhs {
                // Replace the node by one of its operands, id included: the
                // checker's tables are keyed by the operand's own id.
                match e.kind {
                    Binary(_, lhs, _) {
                        ast.overwrite(e, lhs)
                    }
                    else {
                    }
                }
            }
            Rhs {
                match e.kind {
                    Binary(_, _, rhs) {
                        ast.overwrite(e, rhs)
                    }
                    else {
                    }
                }
            }
        }
    }
}

// Merges the literal pieces of an interpolated string: `"a{1 + 1}b"` is `"a2b"`.
fn merge_parts(parts: [ast.StrPart]) -> [ast.StrPart] {
    // A string inside a string is just more pieces.
    var flat: [ast.StrPart] = []
    for part in parts {
        var nested = false
        match part {
            Code(inner) {
                match inner.kind {
                    Str(inner_parts) {
                        for p in inner_parts {
                            flat.push(p)
                        }
                        nested = true
                    }
                    else {
                    }
                }
            }
            else {
            }
        }
        if !nested {
            flat.push(part)
        }
    }
    var merged: [ast.StrPart] = []
    for part in flat {
        var text: [string] = []
        match part {
            Lit(s) {
                text = [s]
            }
            Code(inner) {
                match inner.kind {
                    Int(n) {
                        if is_safe(n) {
                            text = [str(n)]
                        }
                    }
                    Bool(b) {
                        text = [str(b)]
                    }
                    else {
                    }
                }
            }
        }
        if text.len() == 0 {
            merged.push(part)
            continue
        }
        var last = merged.len() - 1
        var appended = false
        if last >= 0 {
            match merged[last] {
                Lit(previous) {
                    merged[last] = ast.StrPart.Lit(previous + text[0])
                    appended = true
                }
                else {
                }
            }
        }
        if !appended {
            merged.push(ast.StrPart.Lit(text[0]))
        }
    }
    if merged.len() == 0 {
        merged.push(ast.StrPart.Lit(""))
    }
    return merged
}

fn simplify(e: ast.Expr) -> Simplified {
    match e.kind {
        Unary(op, inner) {
            match op {
                Neg {
                    match inner.kind {
                        Int(n) {
                            if is_safe(n) {
                                return Simplified.Kind(ast.ExprKind.Int(-n))
                            }
                        }
                        Float(x) {
                            return Simplified.Kind(ast.ExprKind.Float(-x))
                        }
                        else {
                        }
                    }
                }
                Not {
                    match inner.kind {
                        Bool(b) {
                            return Simplified.Kind(ast.ExprKind.Bool(!b))
                        }
                        else {
                        }
                    }
                }
            }
            return Simplified.Same
        }
        Binary(op, lhs, rhs) {
            return binary(op, lhs, rhs)
        }
        else {
            return Simplified.Same
        }
    }
}

fn binary(op: ast.BinOp, lhs: ast.Expr, rhs: ast.Expr) -> Simplified {
    match lhs.kind {
        Int(a) {
            match rhs.kind {
                Int(b) {
                    return int_op(op, a, b)
                }
                Float(b) {
                    return float_op(op, float(a), b)
                }
                else {
                }
            }
        }
        Float(a) {
            match rhs.kind {
                Int(b) {
                    return float_op(op, a, float(b))
                }
                Float(b) {
                    return float_op(op, a, b)
                }
                else {
                }
            }
        }
        Bool(a) {
            match rhs.kind {
                Bool(b) {
                    match op {
                        And {
                            return Simplified.Kind(ast.ExprKind.Bool(a && b))
                        }
                        Or {
                            return Simplified.Kind(ast.ExprKind.Bool(a || b))
                        }
                        Eq {
                            return Simplified.Kind(ast.ExprKind.Bool(a == b))
                        }
                        NotEq {
                            return Simplified.Kind(ast.ExprKind.Bool(a != b))
                        }
                        else {
                            return Simplified.Same
                        }
                    }
                }
                else {
                }
            }
            // With a known left side, `&&` and `||` are either decided or
            // equal to their right side.
            if a && op == ast.BinOp.And {
                return Simplified.Rhs
            }
            if !a && op == ast.BinOp.Or {
                return Simplified.Rhs
            }
            if !a && op == ast.BinOp.And {
                return Simplified.Kind(ast.ExprKind.Bool(false))
            }
            if a && op == ast.BinOp.Or {
                return Simplified.Kind(ast.ExprKind.Bool(true))
            }
        }
        else {
        }
    }
    // With a known right side that changes nothing, they are equal to their
    // left side.
    match rhs.kind {
        Bool(b) {
            if b && op == ast.BinOp.And {
                return Simplified.Lhs
            }
            if !b && op == ast.BinOp.Or {
                return Simplified.Lhs
            }
        }
        else {
        }
    }
    var left = plain_str(lhs)
    var right = plain_str(rhs)
    if left.len() == 0 || right.len() == 0 {
        return Simplified.Same
    }
    var a = left[0]
    var b = right[0]
    match op {
        Add {
            if byte_len(a) + byte_len(b) <= 4096 {
                return Simplified.Kind(ast.ExprKind.Str([ast.StrPart.Lit(a + b)]))
            }
            return Simplified.Same
        }
        Eq {
            return Simplified.Kind(ast.ExprKind.Bool(a == b))
        }
        NotEq {
            return Simplified.Kind(ast.ExprKind.Bool(a != b))
        }
        Lt, Le, Gt, Ge {
            // The targets only agree on the order of plain ASCII text.
            if !is_ascii(a) || !is_ascii(b) {
                return Simplified.Same
            }
            if op == ast.BinOp.Lt {
                return Simplified.Kind(ast.ExprKind.Bool(a < b))
            }
            if op == ast.BinOp.Le {
                return Simplified.Kind(ast.ExprKind.Bool(a <= b))
            }
            if op == ast.BinOp.Gt {
                return Simplified.Kind(ast.ExprKind.Bool(a > b))
            }
            return Simplified.Kind(ast.ExprKind.Bool(a >= b))
        }
        else {
            return Simplified.Same
        }
    }
}

fn int_op(op: ast.BinOp, a: int, b: int) -> Simplified {
    if !is_safe(a) || !is_safe(b) {
        return Simplified.Same
    }
    var value = 0
    match op {
        Add {
            value = a + b
        }
        Sub {
            value = a - b
        }
        Mul {
            // Only when the product stays in range: it is not computed otherwise.
            if a != 0 && b != 0 && abs(a) > MAX_SAFE / abs(b) {
                return Simplified.Same
            }
            value = a * b
        }
        // Dividing by zero must still fail when the program runs.
        Div {
            if b == 0 {
                return Simplified.Same
            }
            value = a / b
        }
        Mod {
            if b == 0 {
                return Simplified.Same
            }
            value = a % b
        }
        Eq {
            return Simplified.Kind(ast.ExprKind.Bool(a == b))
        }
        NotEq {
            return Simplified.Kind(ast.ExprKind.Bool(a != b))
        }
        Lt {
            return Simplified.Kind(ast.ExprKind.Bool(a < b))
        }
        Le {
            return Simplified.Kind(ast.ExprKind.Bool(a <= b))
        }
        Gt {
            return Simplified.Kind(ast.ExprKind.Bool(a > b))
        }
        Ge {
            return Simplified.Kind(ast.ExprKind.Bool(a >= b))
        }
        else {
            return Simplified.Same
        }
    }
    if !is_safe(value) {
        return Simplified.Same
    }
    return Simplified.Kind(ast.ExprKind.Int(value))
}

fn float_op(op: ast.BinOp, a: float, b: float) -> Simplified {
    var value = 0.0
    match op {
        Add {
            value = a + b
        }
        Sub {
            value = a - b
        }
        Mul {
            value = a * b
        }
        Div {
            if b == 0.0 {
                return Simplified.Same
            }
            value = a / b
        }
        Eq {
            return Simplified.Kind(ast.ExprKind.Bool(a == b))
        }
        NotEq {
            return Simplified.Kind(ast.ExprKind.Bool(a != b))
        }
        Lt {
            return Simplified.Kind(ast.ExprKind.Bool(a < b))
        }
        Le {
            return Simplified.Kind(ast.ExprKind.Bool(a <= b))
        }
        Gt {
            return Simplified.Kind(ast.ExprKind.Bool(a > b))
        }
        Ge {
            return Simplified.Kind(ast.ExprKind.Bool(a >= b))
        }
        else {
            return Simplified.Same
        }
    }
    if !is_finite(value) {
        return Simplified.Same
    }
    return Simplified.Kind(ast.ExprKind.Float(value))
}
