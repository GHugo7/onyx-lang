// Works out what every lambda captures.
//
// A lambda may use the variables of the function it is written in, and
// keeps working after that function has returned:
//
//     fn counter() -> fn() -> int {
//         var n = 0
//         return fn() -> int {
//             n += 1
//             return n
//         }
//     }
//
// Natively a lambda is compiled as a function of its own, and its value is
// a small object, the closure, that holds the address of that code and the
// variables it uses. This pass finds those variables.
//
// A captured variable that never changes after its declaration is simply
// copied into the closure. One that is assigned to (like `n` above) has to
// be shared between the function and its lambdas: it moves into a box, a
// one-field object that both sides point to. The pass rewrites the program
// for that:
//
//     var n = 0           var n = $box{v: 0}
//     n += 1        =>    n.v += 1
//     return n            return n.v
//
// so that afterwards every captured variable is one that never changes, and
// the code generator only has to copy values.
//
// Follows src/native/capture.rs.

import "ast"
import "checker"
import "desugar"

// Variables made by this pass get positions past any real source (2^51 and up).
const BOX_POSITIONS = 2251799813685248

// A variable, identified by where it is declared: its position, doubled,
// plus one for `self` (which is identified by the position of its method's
// name).
fn key_of(position: int, is_self: bool) -> int {
    if is_self {
        return position * 2 + 1
    }
    return position * 2
}

fn box_name(ty: checker.Type) -> string {
    return "$box<" + checker.show(ty) + ">"
}

// A variable of an outer function that a lambda uses.
struct Use {
    key: int
    name: string
    ty: checker.Type
}

fn capture(program: ast.Program, an: checker.Analysis) {
    var forks = Forks{an: an, next_id: desugar.next_free_id(an)}
    for item in program.items {
        match item {
            Fn(f) {
                forks.block(f.body)
            }
            Struct(s) {
                for m in s.methods {
                    forks.block(m.body)
                }
            }
            Check(_, body) {
                forks.block(body)
            }
            Global(stmt) {
                forks.stmt(stmt)
            }
            else {
            }
        }
    }

    var finder = Finder{an: an, scopes: [], frames: [], depth_of: {}, assigned: {}, captured: {}, found: {}}
    for item in program.items {
        match item {
            Fn(f) {
                finder.function(f.params, -1, f.body)
            }
            Struct(s) {
                for m in s.methods {
                    finder.function(m.params, m.name_start, m.body)
                }
            }
            Check(_, body) {
                finder.function([], -1, body)
            }
            Global(stmt) {
                finder.push_scope()
                var frame: [Use] = []
                finder.frames.push(frame)
                finder.stmt(stmt)
                finder.frames.remove(finder.frames.len() - 1)
                finder.pop_scope()
            }
            else {
            }
        }
    }
    var boxed: map<int, bool> = {}
    for key in finder.captured.keys() {
        if finder.assigned.has(key) {
            boxed[key] = true
        }
    }

    var captures: map<int, [checker.Captured]> = {}
    var types: map<int, checker.Type> = {}
    for lambda in finder.found.keys() {
        var list: [checker.Captured] = []
        for u in finder.found[lambda] {
            types[u.key] = u.ty
            if boxed.has(u.key) {
                list.push(checker.Captured{name: u.name, ty: checker.Type.Struct(box_name(u.ty))})
            } else {
                list.push(checker.Captured{name: u.name, ty: u.ty})
            }
        }
        captures[lambda] = list
    }
    an.captures = captures
    if boxed.len() == 0 {
        return
    }

    var boxer = Boxer{an: an, boxed: boxed, types: types, scopes: [], next_id: desugar.next_free_id(an), made: 0, before: []}
    for item in program.items {
        match item {
            Fn(f) {
                boxer.function(f.params, -1, f.body)
            }
            Struct(s) {
                for m in s.methods {
                    boxer.function(m.params, m.name_start, m.body)
                }
            }
            Check(_, body) {
                boxer.function([], -1, body)
            }
            Global(stmt) {
                boxer.push_scope()
                boxer.stmt(stmt)
                boxer.pop_scope()
            }
            else {
            }
        }
    }
}

// ---- `fork` blocks ----

// A `fork` block is a lambda handed to the runtime, which runs it as a new
// task: `fork { body }` becomes `__fork(fn() { body })`. From here on it is
// treated like any other lambda (what it uses is captured, and shared with
// the function around it when it changes).
struct Forks {
    an: checker.Analysis
    next_id: int

    fn node(self, kind: ast.ExprKind, ty: checker.Type, start: int, end: int) -> ast.Expr {
        var id = self.next_id
        self.next_id += 1
        self.an.types[id] = ty
        return ast.Expr{id: id, start: start, end: end, kind: kind}
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
            Fork(body) {
                self.block(body)
                self.an.has_forks = true
                var sig = checker.FnSig{params: [], ret: checker.Type.Void, fallible: false}
                var task = self.node(ast.ExprKind.Lambda([], [], false, body), checker.Type.Fn(sig), stmt.start, stmt.end)
                var callee = self.node(ast.ExprKind.Ident("__fork"), checker.Type.Unknown, stmt.start, stmt.end)
                var call = self.node(ast.ExprKind.Call(callee, [task]), checker.Type.Void, stmt.start, stmt.end)
                self.an.calls[call.id] = checker.CallKind.Builtin("__fork")
                stmt.kind = ast.StmtKind.Expr(call)
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
            Block(body) {
                self.block(body)
            }
            Send(channel, value) {
                self.expr(channel)
                self.expr(value)
            }
        }
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

// ---- first walk: who uses what ----

struct Finder {
    an: checker.Analysis
    scopes: [map<string, int>]
    // One entry per function being walked, innermost last: what it captures.
    frames: [[Use]]
    // The function (as an index in `frames`) each variable belongs to.
    depth_of: map<int, int>
    assigned: map<int, bool>
    captured: map<int, bool>
    found: map<int, [Use]>

    fn push_scope(self) {
        var scope: map<string, int> = {}
        self.scopes.push(scope)
    }

    fn pop_scope(self) {
        self.scopes.remove(self.scopes.len() - 1)
    }

    fn declare(self, name: string, key: int) {
        self.depth_of[key] = self.frames.len() - 1
        var scope = self.scopes[self.scopes.len() - 1]
        scope[name] = key
    }

    // The key of the variable `name` names here, or -1.
    fn lookup(self, name: string) -> int {
        var i = self.scopes.len() - 1
        while i >= 0 {
            if self.scopes[i].has(name) {
                return self.scopes[i][name]
            }
            i -= 1
        }
        return -1
    }

    fn touch(self, e: ast.Expr, name: string, assigned: bool) {
        var key = self.lookup(name)
        if key < 0 {
            return
        }
        if assigned {
            self.assigned[key] = true
        }
        var home = self.depth_of[key]
        if home + 1 < self.frames.len() {
            // Used in a lambda: that lambda captures it, and so does every
            // lambda around it up to the function that owns the variable.
            self.captured[key] = true
            var ty = checker.Type.Unknown
            if self.an.types.has(e.id) {
                ty = self.an.types[e.id]
            }
            var first = home + 1
            for d in first..self.frames.len() {
                var frame = self.frames[d]
                var seen = false
                for u in frame {
                    if u.key == key {
                        seen = true
                    }
                }
                if !seen {
                    frame.push(Use{key: key, name: name, ty: ty})
                }
            }
        }
    }

    // `this`: where the name of the method is, or -1 for a function.
    fn function(self, params: [ast.Param], this: int, body: ast.Block) {
        self.push_scope()
        var frame: [Use] = []
        self.frames.push(frame)
        if this >= 0 {
            self.declare("self", key_of(this, true))
        }
        for p in params {
            self.declare(p.name, key_of(p.start, false))
        }
        for stmt in body.stmts {
            self.stmt(stmt)
        }
        self.frames.remove(self.frames.len() - 1)
        self.pop_scope()
    }

    fn block(self, block: ast.Block) {
        self.push_scope()
        for stmt in block.stmts {
            self.stmt(stmt)
        }
        self.pop_scope()
    }

    fn stmt(self, stmt: ast.Stmt) {
        match stmt.kind {
            Match(_, _, _) {
                panic("`match` is rewritten by desugar before this pass")
            }
            Let(name, name_start, _, _, _, init) {
                self.expr(init)
                self.declare(name, key_of(name_start, false))
            }
            Assign(target, _, value) {
                match target.kind {
                    Ident(name) {
                        self.touch(target, name, true)
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
            Return(value) {
                for e in value {
                    self.expr(e)
                }
            }
            Break, Continue {
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
            For(name, name_start, _, iter, body) {
                self.expr(iter)
                self.push_scope()
                self.declare(name, key_of(name_start, false))
                self.block(body)
                self.pop_scope()
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
            Ident(name) {
                self.touch(e, name, false)
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
            Lambda(params, _, _, body) {
                self.push_scope()
                var frame: [Use] = []
                self.frames.push(frame)
                for p in params {
                    self.declare(p.name, key_of(p.start, false))
                }
                for stmt in body.stmts {
                    self.stmt(stmt)
                }
                self.frames.remove(self.frames.len() - 1)
                self.pop_scope()
                self.found[e.id] = frame
            }
            Or(inner, default) {
                self.expr(inner)
                self.expr(default)
            }
            Catch(inner, name, name_start, _, body) {
                self.expr(inner)
                self.push_scope()
                self.declare(name, key_of(name_start, false))
                self.block(body)
                self.pop_scope()
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

// ---- second walk: variables that move into a box ----

struct Boxer {
    an: checker.Analysis
    boxed: map<int, bool>
    // The types of the captured variables.
    types: map<int, checker.Type>
    scopes: [map<string, int>]
    next_id: int
    made: int
    // A statement to put in front of the one being rewritten (none or one).
    before: [ast.Stmt]

    fn node(self, kind: ast.ExprKind, ty: checker.Type, start: int, end: int) -> ast.Expr {
        var id = self.next_id
        self.next_id += 1
        self.an.types[id] = ty
        return ast.Expr{id: id, start: start, end: end, kind: kind}
    }

    fn push_scope(self) {
        var scope: map<string, int> = {}
        self.scopes.push(scope)
    }

    fn pop_scope(self) {
        self.scopes.remove(self.scopes.len() - 1)
    }

    fn set(self, name: string, key: int) {
        var scope = self.scopes[self.scopes.len() - 1]
        scope[name] = key
    }

    fn type_of(self, e: ast.Expr) -> checker.Type {
        if self.an.types.has(e.id) {
            return self.an.types[e.id]
        }
        return checker.Type.Unknown
    }

    // The type of the box for values of type `ty`, declared on first use.
    fn box_type(self, ty: checker.Type) -> checker.Type {
        var name = box_name(ty)
        if !self.an.structs.has(name) {
            var methods: map<string, checker.FnSig> = {}
            self.an.structs[name] = checker.StructInfo{fields: [checker.Field{name: "v", ty: ty}], methods: methods}
        }
        return checker.Type.Struct(name)
    }

    // `$box{v: value}`
    fn wrap(self, value: ast.Expr) -> ast.Expr {
        var ty = self.type_of(value)
        var holder = self.box_type(ty)
        var name = box_name(ty)
        var field = ast.FieldInit{name: "v", name_start: value.start, name_end: value.end, value: value}
        return self.node(ast.ExprKind.StructLit(name, value.start, value.end, [field]), holder, value.start, value.end)
    }

    fn is_boxed(self, name: string) -> bool {
        var i = self.scopes.len() - 1
        while i >= 0 {
            if self.scopes[i].has(name) {
                return self.boxed.has(self.scopes[i][name])
            }
            i -= 1
        }
        return false
    }

    // Parameters that are boxed get their box when the function starts:
    // `var p = $box{v: p}`.
    fn params(self, params: [ast.Param], this: int, body: ast.Block) {
        if this >= 0 {
            self.set("self", key_of(this, true))
        }
        var boxes: [ast.Stmt] = []
        for p in params {
            var key = key_of(p.start, false)
            self.set(p.name, key)
            if self.boxed.has(key) && self.types.has(key) {
                var value = self.node(ast.ExprKind.Ident(p.name), self.types[key], p.start, p.end)
                var init = self.wrap(value)
                self.made += 1
                var position = BOX_POSITIONS + self.made
                boxes.push(ast.Stmt{kind: ast.StmtKind.Let(p.name, position, position, false, [], init), start: p.start, end: p.end})
            }
        }
        self.stmts(body)
        if boxes.len() > 0 {
            for s in body.stmts {
                boxes.push(s)
            }
            body.stmts = boxes
        }
    }

    fn function(self, params: [ast.Param], this: int, body: ast.Block) {
        self.push_scope()
        self.params(params, this, body)
        self.pop_scope()
    }

    fn block(self, block: ast.Block) {
        self.push_scope()
        self.stmts(block)
        self.pop_scope()
    }

    fn stmts(self, block: ast.Block) {
        var out: [ast.Stmt] = []
        for stmt in block.stmts {
            self.stmt(stmt)
            for first in self.before {
                out.push(first)
            }
            self.before = []
            out.push(stmt)
        }
        block.stmts = out
    }

    fn stmt(self, stmt: ast.Stmt) {
        match stmt.kind {
            Match(_, _, _) {
                panic("`match` is rewritten by desugar before this pass")
            }
            Let(name, name_start, name_end, mutable, _, init) {
                self.expr(init)
                var key = key_of(name_start, false)
                if self.boxed.has(key) {
                    var value = init
                    match init.kind {
                        Catch(_, _, _, _, _) {
                            // A `catch` has to stay at the root of a statement:
                            //     var x$v = call() catch err { ... }
                            //     var x = $box{v: x$v}
                            var value_ty = self.type_of(init)
                            self.made += 1
                            var position = BOX_POSITIONS + self.made
                            var temp = name + "$v"
                            self.before = [ast.Stmt{kind: ast.StmtKind.Let(temp, position, position, false, [], init), start: init.start, end: init.end}]
                            value = self.node(ast.ExprKind.Ident(temp), value_ty, init.start, init.end)
                        }
                        else {
                        }
                    }
                    stmt.kind = ast.StmtKind.Let(name, name_start, name_end, mutable, [], self.wrap(value))
                }
                self.set(name, key)
            }
            Assign(target, _, value) {
                self.expr(target)
                self.expr(value)
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
            For(name, name_start, _, iter, body) {
                self.expr(iter)
                self.push_scope()
                self.set(name, key_of(name_start, false))
                self.block(body)
                self.pop_scope()
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
            Ident(name) {
                if self.is_boxed(name) {
                    // The variable now names its box: read (or write) what is inside.
                    var holder = self.box_type(self.type_of(e))
                    var obj = self.node(ast.ExprKind.Ident(name), holder, e.start, e.end)
                    e.kind = ast.ExprKind.Field(obj, "v", e.start, e.end)
                }
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
            Lambda(params, _, _, body) {
                self.function(params, -1, body)
            }
            Or(inner, default) {
                self.expr(inner)
                self.expr(default)
            }
            Catch(inner, name, name_start, _, body) {
                self.expr(inner)
                self.push_scope()
                self.set(name, key_of(name_start, false))
                self.block(body)
                self.pop_scope()
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
