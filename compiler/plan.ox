// Decides, before a function is compiled, which of its variables live in
// processor registers instead of memory.
//
// Every use of a variable is counted, and a use inside a loop counts eight
// times more for each level of nesting. The most used variables get the
// registers; the others stay in the function's stack frame.
//
// Follows src/native/plan.rs.

import "ast"
import "checker"

// A variable of a function is identified by where it is declared in the
// source, and which of the variables declared there it is: the key is the
// position times four, plus one of these.
//
// The variable written in the source.
const NAMED = 0
// Hidden: the limit of a `for i in a..b` loop, or the position in a list loop.
const COUNTER = 1
// Hidden: the list that a `for x in list` loop walks.
const SUBJECT = 2
// The `self` of a method (its position is the method's name).
const SELF = 3

fn var_key(position: int, which: int) -> int {
    return position * 4 + which
}

struct Plan {
    regs: map<int, int>
    // Float variables that are also kept in a float register.
    floats: map<int, int>
    // Variables that are assigned to after their declaration.
    assigned: map<int, bool>
}

// A parameter, as the planner needs it.
struct PlanParam {
    name: string
    key: int
    float: bool
}

struct Candidate {
    key: int
    weight: int
    is_param: bool
    assigned: bool
    float: bool
}

// `types`: the types of the program's expressions, which tell the float
// variables from the others.
fn plan(body: ast.Block, params: [PlanParam], registers: [int], float_registers: [int], types: map<int, checker.Type>) -> Plan {
    var top: map<string, int> = {}
    var p = Planner{types: types, scopes: [top], vars: [], weight: 1}
    for param in params {
        p.declare([param.name], param.key, 0)
        var v = p.vars[p.vars.len() - 1]
        v.is_param = true
        v.float = param.float
    }
    for stmt in body.stmts {
        p.stmt(stmt)
    }

    // A register has to be saved and restored by the function, and a
    // parameter has to be loaded into it: it only pays off for variables
    // used a few times.
    var candidates: [Candidate] = []
    var floats: [Candidate] = []
    for v in p.vars {
        var least = 3
        if v.is_param {
            least = 4
        }
        if !v.float && v.weight >= least {
            candidates.push(v)
        }
        // Floats are computed in registers of their own.
        if v.float && v.weight >= 3 {
            floats.push(v)
        }
    }
    // The most used first; equals keep their order.
    candidates = candidates.sort_by(fn(c: Candidate) -> int {
        return -c.weight
    })
    floats = floats.sort_by(fn(c: Candidate) -> int {
        return -c.weight
    })
    var result = Plan{regs: {}, floats: {}, assigned: {}}
    for i in 0..min(candidates.len(), registers.len()) {
        result.regs[candidates[i].key] = registers[i]
    }
    for i in 0..min(floats.len(), float_registers.len()) {
        result.floats[floats[i].key] = float_registers[i]
    }
    for v in p.vars {
        if v.assigned {
            result.assigned[v.key] = true
        }
    }
    return result
}

struct Planner {
    types: map<int, checker.Type>
    scopes: [map<string, int>]
    vars: [Candidate]
    // What one use is worth at the current loop depth.
    weight: int

    // `name`: none for a hidden variable.
    fn declare(self, name: [string], key: int, uses: int) {
        self.vars.push(Candidate{key: key, weight: uses * self.weight, is_param: false, assigned: false, float: false})
        for n in name {
            var scope = self.scopes[self.scopes.len() - 1]
            scope[n] = self.vars.len() - 1
        }
    }

    fn touch(self, name: string, assigned: bool) {
        var i = self.scopes.len() - 1
        while i >= 0 {
            if self.scopes[i].has(name) {
                var v = self.vars[self.scopes[i][name]]
                v.weight += self.weight
                if assigned {
                    v.assigned = true
                }
                return
            }
            i -= 1
        }
    }

    fn push_scope(self) {
        var scope: map<string, int> = {}
        self.scopes.push(scope)
    }

    fn pop_scope(self) {
        self.scopes.remove(self.scopes.len() - 1)
    }

    // Enters a loop; returns what a use was worth before, for `leave_loop`.
    fn enter_loop(self) -> int {
        var saved = self.weight
        self.weight = min(saved * 8, 32768)
        return saved
    }

    fn leave_loop(self, saved: int) {
        self.weight = saved
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
                self.declare([name], var_key(name_start, NAMED), 1)
                var is_float = self.types.has(init.id) && self.types[init.id] == checker.Type.Float
                self.vars[self.vars.len() - 1].float = is_float
            }
            Assign(target, _, value) {
                match target.kind {
                    Ident(name) {
                        self.touch(name, true)
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
                for other in els {
                    self.stmt(other)
                }
            }
            While(cond, body) {
                var saved = self.enter_loop()
                self.expr(cond)
                self.block(body)
                self.leave_loop(saved)
            }
            For(name, name_start, _, iter, body) {
                var at = name_start
                self.push_scope()
                match iter.kind {
                    Range(lo, hi) {
                        self.expr(lo)
                        self.expr(hi)
                        var constant_limit = false
                        match hi.kind {
                            Int(n) {
                                constant_limit = n >= -2147483648 && n <= 2147483647
                            }
                            else {
                            }
                        }
                        var saved = self.enter_loop()
                        self.declare([name], var_key(at, NAMED), 3)
                        if !constant_limit {
                            self.declare([], var_key(at, COUNTER), 1)
                        }
                        self.block(body)
                        self.leave_loop(saved)
                    }
                    else {
                        self.expr(iter)
                        var saved = self.enter_loop()
                        self.declare([], var_key(at, SUBJECT), 2)
                        self.declare([], var_key(at, COUNTER), 3)
                        self.declare([name], var_key(at, NAMED), 1)
                        self.block(body)
                        self.leave_loop(saved)
                    }
                }
                self.pop_scope()
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
    }

    fn expr(self, e: ast.Expr) {
        match e.kind {
            Ident(name) {
                self.touch(name, false)
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
                // A lambda is a function of its own, planned separately: its
                // variables are followed here only to tell names apart.
                var first = self.vars.len()
                self.push_scope()
                for p in params {
                    self.declare([p.name], var_key(p.start, NAMED), 0)
                }
                for stmt in body.stmts {
                    self.stmt(stmt)
                }
                self.pop_scope()
                for i in first..self.vars.len() {
                    self.vars[i].weight = 0
                }
            }
            Or(inner, default) {
                self.expr(inner)
                self.expr(default)
            }
            Catch(inner, name, name_start, _, body) {
                self.expr(inner)
                self.push_scope()
                self.declare([name], var_key(name_start, NAMED), 0)
                for stmt in body.stmts {
                    self.stmt(stmt)
                }
                self.pop_scope()
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
            else {
            }
        }
    }
}
