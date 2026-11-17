// The native code generator: from a checked and prepared program to an
// x86-64 executable for Linux.
//
// Follows src/native/mod.rs function by function, and must write the same
// bytes. The conventions (registers, calls, reference counting) are
// explained at the top of that file; in short:
//
// - every value is 64 bits wide: an integer, a boolean, a float's bits, or
//   the address of a heap object;
// - an expression leaves its result in RAX; RCX, RDX and R8-R11 are scratch;
// - the most used variables live in RBX, R12, R13, R14, RSI and RDI, float
//   ones also in XMM2-XMM7; R15 holds the address of the runtime's state;
// - the caller pushes the arguments, first to last, and removes them; a
//   function that can fail says in RDX whether it did (its error);
// - references are counted: a computed value is owned by whoever asked for
//   it, arguments are only borrowed by the callee.

import "asm"
import "ast"
import "checker"
import "diag"
import "elf"
import "plan"

// ---- registers and instructions (the numbers of asm.ox) ----

const RAX = 0
const RCX = 1
const RDX = 2
const RBX = 3
const RSP = 4
const RBP = 5
const RSI = 6
const RDI = 7
const R8 = 8
const R9 = 9
const R10 = 10
const R11 = 11
const R12 = 12
const R13 = 13
const R14 = 14
const R15 = 15
const XMM0 = 0
const XMM1 = 1

const ALU_ADD = 0
const ALU_OR = 1
const ALU_AND = 4
const ALU_SUB = 5
const ALU_XOR = 6
const ALU_CMP = 7

const SHIFT_LEFT = 4
const SHIFT_RIGHT = 5
const SHIFT_RIGHT_SIGNED = 7

const CC_B = 0x2
const CC_AE = 0x3
const CC_E = 0x4
const CC_NE = 0x5
const CC_BE = 0x6
const CC_A = 0x7
const CC_P = 0xA
const CC_NP = 0xB
const CC_L = 0xC
const CC_GE = 0xD
const CC_LE = 0xE
const CC_G = 0xF

const SSE_MOV = 0x10
const SSE_SQRT = 0x51
const SSE_ADD = 0x58
const SSE_MUL = 0x59
const SSE_SUB = 0x5C
const SSE_DIV = 0x5E

// ---- layout ----

// Size of the runtime's state. The top-level variables, then the method
// caches of interface calls, are stored right after it.
const STATE_SIZE = 4096

// Offsets inside heap objects (see runtime.ox).
const COUNT = 0
const DESCRIPTOR = 4
const LIST_LEN = 8
const LIST_CAP = 16
const LIST_DATA = 24
const FIELDS = 8

// Where the test runner notes, in the runtime's state, the stack pointer
// and the address to come back to when a check is abandoned.
const TEST_STACK = 1152
const TEST_RESUME = 1160
// In the runtime's state: the running task, the first task that is ready
// to go on, and whether the last receive from a channel got a value.
const CURRENT_TASK = 1184
const READY_TASKS = 1200
const CHAN_OK = 1240
// In a task: the function it runs.
const TASK_CLOSURE = 32

// Stack space in which the runtime writes the text of a number (see
// `__rt_int_into` in runtime.ox).
const NUMBER_BUFFER = 40

// Registers that hold local variables.
fn variable_regs() -> [int] {
    return [RBX, R12, R13, R14, RSI, RDI]
}

// Registers that hold float variables (XMM0 and XMM1 are for computing).
fn float_regs() -> [int] {
    return [2, 3, 4, 5, 6, 7]
}

// ---- helpers ----

fn is_ref(ty: checker.Type) -> bool {
    match ty {
        Str, Error {
            return true
        }
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
        Fn(_) {
            return true
        }
        Chan(_) {
            return true
        }
        Weak(_) {
            return true
        }
        Enum(_) {
            return true
        }
        else {
            return false
        }
    }
}

fn supported(ty: checker.Type) -> bool {
    match ty {
        Fn(sig) {
            for p in sig.params {
                if !supported(p) {
                    return false
                }
            }
            return supported(sig.ret)
        }
        List(elem) {
            return supported(elem)
        }
        Chan(elem) {
            return supported(elem)
        }
        Weak(elem) {
            return supported(elem)
        }
        Map(key, value) {
            return key != checker.Type.Float && supported(key) && supported(value)
        }
        else {
            return true
        }
    }
}

// The text of a string literal without interpolation (none: it has some).
fn plain(parts: [ast.StrPart]) -> [string] {
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

// Does control never reach the end of this block?
fn leaves(block: ast.Block) -> bool {
    if block.stmts.len() == 0 {
        return false
    }
    match block.stmts[block.stmts.len() - 1].kind {
        Return(_), Break, Continue, Fail(_) {
            return true
        }
        else {
            return false
        }
    }
}

fn cc_of(op: ast.BinOp) -> int {
    match op {
        Eq {
            return CC_E
        }
        NotEq {
            return CC_NE
        }
        Lt {
            return CC_L
        }
        Le {
            return CC_LE
        }
        Gt {
            return CC_G
        }
        else {
            return CC_GE
        }
    }
}

fn is_catch(e: ast.Expr) -> bool {
    match e.kind {
        Catch(_, _, _, _, _) {
            return true
        }
        else {
            return false
        }
    }
}

fn is_bool(e: ast.Expr, value: bool) -> bool {
    match e.kind {
        Bool(b) {
            return b == value
        }
        else {
            return false
        }
    }
}

// Unsigned comparison of two 64-bit numbers: is `a` below `b`?
fn below(a: int, b: int) -> bool {
    return (a ^ 0x8000000000000000) < (b ^ 0x8000000000000000)
}

// Unsigned division and remainder of 64-bit numbers.
fn udiv(a: int, b: int) -> int {
    if b < 0 {
        // b is at least 2^63: the quotient is 0 or 1.
        if below(a, b) {
            return 0
        }
        return 1
    }
    // Halve, divide, then correct by at most one.
    var q = (a >> 1 & 0x7FFFFFFFFFFFFFFF) / b << 1
    var r = a - q * b
    if !below(r, b) {
        q += 1
    }
    return q
}

fn urem(a: int, b: int) -> int {
    return a - udiv(a, b) * b
}

// For dividing by the constant `d` with a multiplication (Hacker's Delight,
// "Signed division by constants"): returns [magic, shift] such that `n / d`
// is `high64(magic * n)`, corrected by `n` when the signs of `magic` and `d`
// differ, shifted right by `shift`, plus one when negative. `d` must not be
// 0, 1 or -1. The numbers are unsigned 64-bit ones, as in the original.
fn magic_number(d: int) -> [int] {
    var two63 = 0x8000000000000000
    var ad = abs(d)
    var t = two63 + (d >> 63 & 1)
    var anc = t - 1 - urem(t, ad)
    var p = 63
    var q1 = udiv(two63, anc)
    var r1 = two63 - q1 * anc
    var q2 = udiv(two63, ad)
    var r2 = two63 - q2 * ad
    while true {
        p += 1
        q1 = q1 * 2
        r1 = r1 * 2
        if !below(r1, anc) {
            q1 += 1
            r1 -= anc
        }
        q2 = q2 * 2
        r2 = r2 * 2
        if !below(r2, ad) {
            q2 += 1
            r2 -= ad
        }
        var delta = ad - r2
        if !(below(q1, delta) || (q1 == delta && r1 == 0)) {
            break
        }
    }
    var magic = q2 + 1
    if d < 0 {
        magic = -magic
    }
    return [magic, p - 64]
}

fn is_comparison(op: ast.BinOp) -> bool {
    match op {
        Eq, NotEq, Lt, Le, Gt, Ge {
            return true
        }
        else {
            return false
        }
    }
}

fn is_arith(op: ast.BinOp) -> bool {
    match op {
        Add, Sub, Mul, Div, Mod {
            return true
        }
        else {
            return false
        }
    }
}

fn is_struct(ty: checker.Type) -> bool {
    match ty {
        Struct(_) {
            return true
        }
        else {
            return false
        }
    }
}

fn is_list(ty: checker.Type) -> bool {
    match ty {
        List(_) {
            return true
        }
        else {
            return false
        }
    }
}

// Built-in functions that run no code of the program.
fn harmless_builtins() -> [string] {
    return ["str", "abs", "min", "max", "float", "int", "sqrt", "pow", "floor", "ceil", "round", "bit_and", "bit_or", "bit_xor", "bit_not", "shift_left", "shift_right"]
}

// The low 32 bits of `v`, as a signed number (what Rust's `as i32` gives).
fn as_i32(v: int) -> int {
    return v << 32 >> 32
}

// Is `v`, read as an unsigned number, a power of two?
fn is_power_of_two(v: int) -> bool {
    return v != 0 && v & (v - 1) == 0
}

// The number of zero bits below the lowest one.
fn trailing_zeros(v: int) -> int {
    var n = 0
    while n < 64 && (v >> n) & 1 == 0 {
        n += 1
    }
    return n
}

// The pieces of `a + b + c`, strings: each operand that is not itself a sum.
fn add_leaves(e: ast.Expr, out: [Piece]) {
    match e.kind {
        Binary(op, lhs, rhs) {
            if op == ast.BinOp.Add {
                add_leaves(lhs, out)
                add_leaves(rhs, out)
                return
            }
        }
        Str(parts) {
            for text in plain(parts) {
                out.push(Piece.Text(text))
                return
            }
        }
        else {
        }
    }
    out.push(Piece.Code(e))
}

// Adds text to the pieces of a string, after the text that ends them if any.
fn add_text(pieces: [Piece], s: string) {
    var last = pieces.len() - 1
    if last >= 0 {
        match pieces[last] {
            Text(previous) {
                pieces[last] = Piece.Text(previous + s)
                return
            }
            else {
            }
        }
    }
    if s != "" {
        pieces.push(Piece.Text(s))
    }
}

// What `push_pieces` left on the stack.
struct Pushed {
    owned: [bool]
    // Bytes above the pieces that hold the text of numbers.
    extra: int
}

// The four operations SSE does on floats.
fn is_float_op(op: ast.BinOp) -> bool {
    match op {
        Add, Sub, Mul, Div {
            return true
        }
        else {
            return false
        }
    }
}

fn sse_of(op: ast.BinOp) -> int {
    match op {
        Add {
            return SSE_ADD
        }
        Sub {
            return SSE_SUB
        }
        Mul {
            return SSE_MUL
        }
        else {
            return SSE_DIV
        }
    }
}

fn int_like(ty: checker.Type) -> bool {
    return ty == checker.Type.Int || ty == checker.Type.Bool
}

// The condition to test after the two compared operands were exchanged.
fn swap_cc(cc: int) -> int {
    if cc == CC_L {
        return CC_G
    }
    if cc == CC_G {
        return CC_L
    }
    if cc == CC_LE {
        return CC_GE
    }
    if cc == CC_GE {
        return CC_LE
    }
    return cc
}

// ---- what the generator works with ----

// Where a variable lives.
enum Loc {
    Reg(int)
    // Offset from RBP: a parameter or a local variable.
    Frame(int)
    // Offset from R15: a top-level variable.
    Global(int)
}

// Something an instruction can use directly, without computing it first.
enum Operand {
    Imm(int)
    At(Loc)
}

fn is_global(loc: Loc) -> bool {
    match loc {
        Global(_) {
            return true
        }
        else {
            return false
        }
    }
}

// The register an operand is in (-1: it is not in one).
fn operand_reg(operand: Operand) -> int {
    match operand {
        At(loc) {
            match loc {
                Reg(r) {
                    return r
                }
                else {
                    return -1
                }
            }
        }
        else {
            return -1
        }
    }
}

fn is_global_operand(operand: Operand) -> bool {
    match operand {
        At(loc) {
            return is_global(loc)
        }
        else {
            return false
        }
    }
}

struct Var {
    name: string
    loc: Loc
    is_ref: bool
    // The variable holds a reference of its own, released when it goes away.
    // False for parameters, which are borrowed from the caller.
    owned: bool
}

struct VarRef {
    loc: Loc
    is_ref: bool
    owned: bool
}

struct Loop {
    next: int
    end: int
    // `continue` / `break` release the variables of the scopes from this index on.
    continue_from: int
    break_from: int
}

struct ParamInfo {
    name: string
    ty: checker.Type
    key: int
    start: int
    end: int
}

struct FnItem {
    body: ast.Block
    fallible: bool
    // Where to report a problem with the return type.
    start: int
    end: int
    params: [ParamInfo]
    ret: checker.Type
    // For a lambda: the variables it takes from the functions around it.
    captures: [checker.Captured]
}

struct GlobalVar {
    offset: int
    ty: checker.Type
}

// An argument of a call to the runtime.
enum Arg {
    // A reference the runtime only looks at.
    Borrow(ast.Expr)
    // A reference whose ownership passes to the runtime (stored in a list...).
    Move(ast.Expr)
    // An integer or a boolean.
    Value(ast.Expr)
    Const(int)
    Descriptor(checker.Type)
}

// Where the value of a `call() catch err { ... }` goes.
enum Sink {
    // Into a variable that is being declared.
    Var(Loc)
    // Into an existing variable.
    Assign(VarRef)
    // Out of the function.
    Return
    // Nowhere: the expression is a statement.
    Discard
}

// A piece of a string being assembled.
enum Piece {
    Text(string)
    Code(ast.Expr)
}

struct PendingDescriptor {
    ty: checker.Type
    label: int
}

struct PendingClosure {
    captures: [checker.Type]
    label: int
}

struct PendingStatic {
    key: string
    label: int
}

struct PendingVariant {
    name: string
    index: int
    label: int
}

struct Check {
    key: string
    name: string
}

// Every lambda of a block, those nested in other lambdas included.
fn lambdas_in(block: ast.Block, out: [ast.Expr]) {
    for s in block.stmts {
        lambdas_in_stmt(s, out)
    }
}

fn lambdas_in_stmt(s: ast.Stmt, out: [ast.Expr]) {
    match s.kind {
        Match(_, _, _) {
            panic("`match` is rewritten by desugar before this pass")
        }
        Let(_, _, _, _, _, init) {
            lambdas_in_expr(init, out)
        }
        Expr(e) {
            lambdas_in_expr(e, out)
        }
        Fail(e) {
            lambdas_in_expr(e, out)
        }
        Return(value) {
            for e in value {
                lambdas_in_expr(e, out)
            }
        }
        Break, Continue {
        }
        Assign(target, _, value) {
            lambdas_in_expr(target, out)
            lambdas_in_expr(value, out)
        }
        If(cond, then, els) {
            lambdas_in_expr(cond, out)
            lambdas_in(then, out)
            for other in els {
                lambdas_in_stmt(other, out)
            }
        }
        While(cond, body) {
            lambdas_in_expr(cond, out)
            lambdas_in(body, out)
        }
        For(_, _, _, iter, body) {
            lambdas_in_expr(iter, out)
            lambdas_in(body, out)
        }
        Fork(body) {
            lambdas_in(body, out)
        }
        Block(body) {
            lambdas_in(body, out)
        }
        Send(channel, value) {
            lambdas_in_expr(channel, out)
            lambdas_in_expr(value, out)
        }
    }
}

fn lambdas_in_expr(e: ast.Expr, out: [ast.Expr]) {
    match e.kind {
        Lambda(_, _, _, body) {
            out.push(e)
            lambdas_in(body, out)
        }
        Str(parts) {
            for part in parts {
                match part {
                    Code(inner) {
                        lambdas_in_expr(inner, out)
                    }
                    else {
                    }
                }
            }
        }
        List(items) {
            for item in items {
                lambdas_in_expr(item, out)
            }
        }
        Map(entries) {
            for entry in entries {
                lambdas_in_expr(entry.key, out)
                lambdas_in_expr(entry.value, out)
            }
        }
        StructLit(_, _, _, fields) {
            for f in fields {
                lambdas_in_expr(f.value, out)
            }
        }
        Unary(_, inner) {
            lambdas_in_expr(inner, out)
        }
        Try(inner) {
            lambdas_in_expr(inner, out)
        }
        Recv(inner) {
            lambdas_in_expr(inner, out)
        }
        Field(obj, _, _, _) {
            lambdas_in_expr(obj, out)
        }
        Binary(_, lhs, rhs) {
            lambdas_in_expr(lhs, out)
            lambdas_in_expr(rhs, out)
        }
        Index(obj, index) {
            lambdas_in_expr(obj, out)
            lambdas_in_expr(index, out)
        }
        Range(lo, hi) {
            lambdas_in_expr(lo, out)
            lambdas_in_expr(hi, out)
        }
        Call(callee, args) {
            lambdas_in_expr(callee, out)
            for arg in args {
                lambdas_in_expr(arg, out)
            }
        }
        Or(inner, default) {
            lambdas_in_expr(inner, out)
            lambdas_in_expr(default, out)
        }
        Catch(inner, _, _, _, body) {
            lambdas_in_expr(inner, out)
            lambdas_in(body, out)
        }
        ChanNew(_, cap) {
            for c in cap {
                lambdas_in_expr(c, out)
            }
        }
        else {
        }
    }
}

// ---- the program ----

// Compiles a checked program into an executable. Fails after noting the
// problems in `report` (things the native target cannot do yet).
fn generate(program: ast.Program, an: checker.Analysis, leak_check: bool, report: diag.Report) -> [int]! {
    var g = Gen{
        an: an,
        asm: asm.new_asm(),
        report: report,
        items: {},
        labels: {},
        requested: {},
        queue: [],
        globals: {},
        strings: {},
        descriptors: {},
        pending_descriptors: [],
        pending_closures: [],
        static_closures: {},
        pending_statics: [],
        plain_variants: {},
        pending_variants: [],
        caches: 0,
        div_zero: -1,
        index_oob: -1,
        switch: -1,
        task_entry: -1,
        fault_entry: -1,
        scopes: [],
        regs: {},
        float_regs: {},
        in_xmm: {},
        slots: 0,
        loops: [],
        epilogue: -1,
        at_tail: false,
        fallible: false,
        keep_error: false,
        rt_fallible: false
    }

    // Every function gets a label. Its code is only generated when something refers to it.
    var global_order: [string] = []
    var lambdas: [ast.Expr] = []
    for item in program.items {
        match item {
            Fn(f) {
                if an.fns.has(f.name) {
                    var sig = an.fns[f.name]
                    var params: [ParamInfo] = []
                    for i in 0..min(f.params.len(), sig.params.len()) {
                        var p = f.params[i]
                        params.push(ParamInfo{name: p.name, ty: sig.params[i], key: plan.var_key(p.start, plan.NAMED), start: p.ty.start, end: p.ty.end})
                    }
                    lambdas_in(f.body, lambdas)
                    var captures: [checker.Captured] = []
                    var fn_item = FnItem{body: f.body, fallible: f.fallible, start: f.name_start, end: f.name_end, params: params, ret: sig.ret, captures: captures}
                    g.add_function(f.name, fn_item)
                }
            }
            Struct(s) {
                for m in s.methods {
                    var sig = an.structs[s.name].methods[m.name]
                    var self_param = ParamInfo{name: "self", ty: checker.Type.Struct(s.name), key: plan.var_key(m.name_start, plan.SELF), start: m.name_start, end: m.name_end}
                    var params = [self_param]
                    for i in 0..min(m.params.len(), sig.params.len()) {
                        var p = m.params[i]
                        params.push(ParamInfo{name: p.name, ty: sig.params[i], key: plan.var_key(p.start, plan.NAMED), start: p.ty.start, end: p.ty.end})
                    }
                    lambdas_in(m.body, lambdas)
                    var captures: [checker.Captured] = []
                    var fn_item = FnItem{body: m.body, fallible: m.fallible, start: m.name_start, end: m.name_end, params: params, ret: sig.ret, captures: captures}
                    g.add_function(checker.method_key(s.name, m.name), fn_item)
                }
            }
            Global(stmt) {
                match stmt.kind {
                    Let(name, _, _, _, _, init) {
                        match init.kind {
                            Lambda(_, _, _, body) {
                                lambdas.push(init)
                                lambdas_in(body, lambdas)
                            }
                            else {
                            }
                        }
                        var offset = STATE_SIZE + 8 * global_order.len()
                        g.globals[name] = GlobalVar{offset: offset, ty: g.ty(init)}
                        global_order.push(name)
                    }
                    else {
                    }
                }
            }
            else {
            }
        }
    }
    // A lambda is one more function, with a hidden extra: the closure it runs for.
    for lambda in lambdas {
        match lambda.kind {
            Lambda(lambda_params, _, fallible, body) {
                match g.ty(lambda) {
                    Fn(sig) {
                        var params: [ParamInfo] = []
                        for i in 0..min(lambda_params.len(), sig.params.len()) {
                            var p = lambda_params[i]
                            params.push(ParamInfo{name: p.name, ty: sig.params[i], key: plan.var_key(p.start, plan.NAMED), start: p.ty.start, end: p.ty.end})
                        }
                        var captures: [checker.Captured] = []
                        if an.captures.has(lambda.id) {
                            captures = an.captures[lambda.id]
                        }
                        var fn_item = FnItem{body: body, fallible: fallible, start: lambda.start, end: lambda.end, params: params, ret: sig.ret, captures: captures}
                        g.add_function(checker.lambda_key(lambda.id), fn_item)
                    }
                    else {
                    }
                }
            }
            else {
            }
        }
    }
    g.descriptor(checker.Type.Str)

    // Program entry: map the state, give the top-level variables their values, run main.
    var entry = g.asm.pos()
    g.asm.mov_imm(RAX, 9)                       // mmap(NULL, size, READ | WRITE, PRIVATE | ANONYMOUS, -1, 0)
    g.asm.mov_imm(RDI, 0)
    var state_size_at = g.asm.mov_imm32_patchable(RSI, 0)
    g.asm.mov_imm(RDX, 3)
    g.asm.mov_imm(R10, 0x22)
    g.asm.mov_imm(R8, -1)
    g.asm.mov_imm(R9, 0)
    g.asm.syscall()
    g.asm.mov(R15, RAX)
    // The stack is still as the kernel made it: remember where the
    // arguments and the environment are.
    g.asm.store(R15, 1104, RSP)
    g.asm.mov(RBP, RSP)
    g.call_runtime("__rt_watch_stack", 0)
    for item in program.items {
        match item {
            Global(stmt) {
                match stmt.kind {
                    Let(name, _, _, _, _, init) {
                        g.expr_into(init, Loc.Global(g.globals[name].offset))
                    }
                    else {
                    }
                }
            }
            else {
            }
        }
    }
    if g.items.has("main") {
        var can_fail = g.items["main"].fallible
        var label = g.function_label("main")
        g.asm.call(label)
        if can_fail {
            // An error that nobody handled ends the program.
            g.asm.test(RDX, RDX)
            var fine = g.asm.jcc_short(CC_E)
            g.asm.push(RDX)
            g.call_runtime("__rt_main_failed", 0)
            g.asm.bind_short(fine)
        }
    }
    if an.has_forks {
        // `main` is done; the tasks it started may not be.
        g.call_runtime("__rt_finish", 0)
    }
    if leak_check {
        var i = global_order.len() - 1
        while i >= 0 {
            var global = g.globals[global_order[i]]
            if is_ref(global.ty) {
                g.asm.load(RAX, R15, global.offset)
                g.release_rax()
            }
            i -= 1
        }
        g.call_runtime("__rt_leak_check", 0)
    }
    g.asm.push_imm(0)
    g.call_runtime("__rt_exit", 0)

    // Compile what was asked for, which may ask for more.
    while true {
        if g.queue.len() > 0 {
            var key = g.queue.remove(g.queue.len() - 1)
            g.function(key)
        } else if !(g.emit_stubs() || g.emit_descriptors()) {
            break
        }
    }
    g.emit_strings()

    var state_bytes = STATE_SIZE + 8 * global_order.len() + 16 * g.caches
    g.asm.patch32(state_size_at, (state_bytes + 4095) / 4096 * 4096)

    if report.diags.len() > 0 {
        var sorted = report.diags.sort_by(fn(d: diag.Diag) -> int {
            return d.start
        })
        // The same problem met twice (in two copies of a function) is told once.
        var kept: [diag.Diag] = []
        for d in sorted {
            var last = kept.len() - 1
            if last < 0 || kept[last].start != d.start || kept[last].message != d.message {
                kept.push(d)
            }
        }
        report.diags = kept
        fail "native"
    }
    return elf.write(g.asm.finish(elf.IMAGE_BASE), entry)
}

struct Gen {
    an: checker.Analysis
    asm: asm.Asm
    report: diag.Report
    // Every function and method of the program, by name (or method key).
    items: map<string, FnItem>
    labels: map<string, int>
    // Functions that are referred to, and those among them still to compile.
    requested: map<string, bool>
    queue: [string]
    // Top-level variables: where they are, from R15, and their types.
    globals: map<string, GlobalVar>
    strings: map<string, int>
    // Type (by its name) -> its descriptor table.
    descriptors: map<string, int>
    pending_descriptors: [PendingDescriptor]
    pending_closures: [PendingClosure]
    static_closures: map<string, int>
    pending_statics: [PendingStatic]
    // Variants that carry nothing, each a constant object ("Enum#index").
    plain_variants: map<string, int>
    pending_variants: [PendingVariant]
    // Number of interface call sites; each has a two-word cache after the globals.
    caches: int
    // Shared pieces of code that report an error and never return (-1: none yet).
    div_zero: int
    index_oob: int
    // The code that passes the processor from one task to another, and the
    // code every task starts in.
    switch: int
    task_entry: int
    // Where the kernel sends the program when it touches memory it may not.
    fault_entry: int

    // ---- state of the function being compiled ----
    // Local variables, innermost scope last.
    scopes: [[Var]]
    // The variables that were given a register.
    regs: map<int, int>
    // Float variables that are also kept in a float register, and, once
    // they are declared, by the frame slot each one lives in. The slot
    // always holds the value too: a call may use the float registers for
    // something else, and they are loaded again after it.
    float_regs: map<int, int>
    in_xmm: map<int, int>
    // Frame slots used so far.
    slots: int
    loops: [Loop]
    epilogue: int
    // The statement being compiled is the last one of the function body.
    at_tail: bool
    // The function being compiled can fail: it reports in RDX whether it did.
    fallible: bool
    // The call whose arguments are about to be dropped can fail: RDX matters.
    keep_error: bool
    // The runtime function about to be called can fail.
    rt_fallible: bool

    fn unsupported(self, start: int, end: int, what: string) {
        var d = self.report.add("E0500", what + " are not supported by the native target yet", start, end)
        d.help = "the native target is new and grows step by step; this program still runs with `onyx run`"
    }

    fn check_type(self, ty: checker.Type, start: int, end: int) {
        if !supported(ty) {
            self.unsupported(start, end, "values of type `" + checker.show(ty) + "`")
        }
    }

    fn ty(self, e: ast.Expr) -> checker.Type {
        if self.an.types.has(e.id) {
            return self.an.types[e.id]
        }
        return checker.Type.Unknown
    }

    // The built-in function `e` calls ("" for anything else).
    fn builtin_name(self, e: ast.Expr) -> string {
        if self.an.calls.has(e.id) {
            match self.an.calls[e.id] {
                Builtin(name) {
                    return name
                }
                else {
                }
            }
        }
        return ""
    }

    // ---- functions, on demand ----

    fn add_function(self, key: string, item: FnItem) {
        var label = self.asm.new_label()
        self.labels[key] = label
        self.items[key] = item
    }

    // The address of a function, which gets compiled if it was not yet.
    fn function_label(self, key: string) -> int {
        if !self.labels.has(key) {
            panic("unknown function `{key}`")
        }
        if !self.requested.has(key) {
            self.requested[key] = true
            self.queue.push(key)
        }
        return self.labels[key]
    }

    // Calls a runtime function whose arguments are already on the stack, and
    // removes `drop` of them afterwards.
    fn call_runtime(self, name: string, drop: int) {
        var label = self.function_label(name)
        self.asm.call(label)
        self.reload_floats()
        if drop > 0 {
            self.asm.alu_imm(ALU_ADD, RSP, 8 * drop)
        }
    }

    // ---- constants ----

    fn string(self, text: string) -> int {
        if self.strings.has(text) {
            return self.strings[text]
        }
        var label = self.asm.new_label()
        self.strings[text] = label
        return label
    }

    // The descriptor table of a type; it is written out by `emit_descriptors`.
    fn descriptor(self, given: checker.Type) -> int {
        // An error is its message: a string.
        var ty = given
        if ty == checker.Type.Error {
            ty = checker.Type.Str
        }
        var key = checker.show(ty)
        if self.descriptors.has(key) {
            return self.descriptors[key]
        }
        var label = self.asm.new_label()
        self.descriptors[key] = label
        self.pending_descriptors.push(PendingDescriptor{ty: ty, label: label})
        return label
    }

    fn emit_descriptors(self) -> bool {
        if self.pending_descriptors.len() == 0 && self.pending_closures.len() == 0 && self.pending_statics.len() == 0 && self.pending_variants.len() == 0 {
            return false
        }
        while self.pending_descriptors.len() > 0 {
            var pending = self.pending_descriptors.remove(self.pending_descriptors.len() - 1)
            var label = pending.label
            self.asm.align(8)
            match pending.ty {
                List(elem) {
                    var elem_td = self.descriptor(elem)
                    self.asm.bind(label)
                    self.asm.word(4)
                    self.asm.address(elem_td)
                }
                Enum(name) {
                    // The enum's name, then for each variant the address of
                    // its own table: its name and the descriptors of what
                    // it carries.
                    var variants = self.an.enums[name]
                    var name_label = self.string(name)
                    var tables: [int] = []
                    var variant_names: [int] = []
                    var variant_fields: [[int]] = []
                    for v in variants {
                        var fields: [int] = []
                        for field_ty in v.fields {
                            fields.push(self.descriptor(field_ty))
                        }
                        tables.push(self.asm.new_label())
                        variant_names.push(self.string(v.name))
                        variant_fields.push(fields)
                    }
                    self.asm.bind(label)
                    self.asm.word(12)
                    self.asm.address(name_label)
                    self.asm.word(tables.len())
                    for table in tables {
                        self.asm.address(table)
                    }
                    for i in 0..tables.len() {
                        self.asm.bind(tables[i])
                        self.asm.address(variant_names[i])
                        self.asm.word(variant_fields[i].len())
                        for td in variant_fields[i] {
                            self.asm.address(td)
                        }
                    }
                }
                Chan(elem) {
                    // Written like the descriptor of a struct with seven
                    // fields, the third of which is the list of buffered
                    // values, so that a channel is released like a struct.
                    var name = self.string("chan")
                    var int_td = self.descriptor(checker.Type.Int)
                    var buffer = self.descriptor(checker.Type.List(elem))
                    self.asm.bind(label)
                    self.asm.word(10)
                    self.asm.address(name)
                    self.asm.word(7)
                    self.asm.word(0)
                    for field in 0..7 {
                        self.asm.address(name)
                        if field == 2 {
                            self.asm.address(buffer)
                        } else {
                            self.asm.address(int_td)
                        }
                    }
                }
                Map(key, value) {
                    var key_td = self.descriptor(key)
                    var value_td = self.descriptor(value)
                    self.asm.bind(label)
                    self.asm.word(7)
                    self.asm.address(key_td)
                    self.asm.address(value_td)
                }
                Struct(name) {
                    var info = self.an.structs[name]
                    var name_label = self.string(name)
                    var field_names: [int] = []
                    var field_tds: [int] = []
                    for f in info.fields {
                        field_names.push(self.string(f.name))
                        field_tds.push(self.descriptor(f.ty))
                    }
                    // Any method may be called through an interface, so all of them are kept.
                    var method_names: [int] = []
                    var method_code: [int] = []
                    for method in info.methods.keys().sort() {
                        method_names.push(self.string(method))
                        method_code.push(self.function_label(checker.method_key(name, method)))
                    }
                    var table = self.asm.new_label()

                    self.asm.bind(label)
                    self.asm.word(5)
                    self.asm.address(name_label)
                    self.asm.word(field_names.len())
                    self.asm.address(table)
                    for i in 0..field_names.len() {
                        self.asm.address(field_names[i])
                        self.asm.address(field_tds[i])
                    }
                    self.asm.bind(table)
                    self.asm.word(method_names.len())
                    for i in 0..method_names.len() {
                        self.asm.address(method_names[i])
                        self.asm.address(method_code[i])
                    }
                }
                else {
                    var kind = 0
                    match pending.ty {
                        // A weak reference: a cell that holds the address
                        // of its object, or 0 once the object is gone.
                        Weak(_) {
                            kind = 11
                        }
                        Bool {
                            kind = 1
                        }
                        Float {
                            kind = 2
                        }
                        Str {
                            kind = 3
                        }
                        // Like an interface value, a function value says
                        // what it is itself (see `closure_descriptor`).
                        Interface(_) {
                            kind = 6
                        }
                        Fn(_) {
                            kind = 6
                        }
                        else {
                        }
                    }
                    self.asm.bind(label)
                    self.asm.word(kind)
                }
            }
        }
        while self.pending_closures.len() > 0 {
            var pending = self.pending_closures.remove(self.pending_closures.len() - 1)
            // Laid out like the descriptor of a struct whose first field is
            // the address of the code, so that releasing a closure is
            // releasing a struct. Kind 9 instead of 5 tells them apart.
            var name = self.string("fn")
            var int_td = self.descriptor(checker.Type.Int)
            var fields: [int] = []
            for ty in pending.captures {
                fields.push(self.descriptor(ty))
            }
            self.asm.align(8)
            self.asm.bind(pending.label)
            self.asm.word(9)
            self.asm.address(name)
            self.asm.word(1 + fields.len())
            self.asm.word(0)
            self.asm.address(name)
            self.asm.address(int_td)
            for td in fields {
                self.asm.address(name)
                self.asm.address(td)
            }
        }
        while self.pending_variants.len() > 0 {
            var pending = self.pending_variants.remove(self.pending_variants.len() - 1)
            // A variant that carries nothing: one constant, never released.
            var td = self.descriptor(checker.Type.Enum(pending.name))
            self.asm.align(8)
            self.asm.bind(pending.label)
            self.asm.half(-1)
            self.asm.address32(td)
            self.asm.word(pending.index)
        }
        while self.pending_statics.len() > 0 {
            var pending = self.pending_statics.remove(self.pending_statics.len() - 1)
            // A function that captures nothing: one constant closure, never released.
            var td = self.closure_descriptor([])
            var code = self.function_label(pending.key)
            self.asm.align(8)
            self.asm.bind(pending.label)
            self.asm.half(-1)
            self.asm.address32(td)
            self.asm.address(code)
        }
        return true
    }

    // The descriptor of closures that capture values of these types.
    fn closure_descriptor(self, captures: [checker.Type]) -> int {
        var key = "closure(" + captures.map(checker.show).join(", ") + ")"
        if self.descriptors.has(key) {
            return self.descriptors[key]
        }
        var label = self.asm.new_label()
        self.descriptors[key] = label
        self.pending_closures.push(PendingClosure{captures: captures, label: label})
        return label
    }

    // The closure of a function (or lambda) that captures nothing.
    fn static_closure(self, key: string) -> int {
        if self.static_closures.has(key) {
            return self.static_closures[key]
        }
        var label = self.asm.new_label()
        self.static_closures[key] = label
        self.pending_statics.push(PendingStatic{key: key, label: label})
        return label
    }

    // String constants: a header marking them as never released, then the text.
    fn emit_strings(self) {
        var string_td = self.descriptor(checker.Type.Str)
        for text in self.strings.keys().sort() {
            var data = bytes(text)
            self.asm.align(8)
            self.asm.bind(self.strings[text])
            self.asm.half(-1)
            self.asm.address32(string_td)
            self.asm.half(data.len())
            self.asm.half(data.len())
            self.asm.bytes(data)
        }
    }

    // The shared error paths, written once and jumped to from everywhere.
    fn emit_stubs(self) -> bool {
        var emitted = false
        if self.div_zero >= 0 && !self.asm.is_bound(self.div_zero) {
            self.asm.bind(self.div_zero)
            var message = self.string("division by zero")
            self.asm.lea(RAX, message)
            self.asm.push(RAX)
            self.call_runtime("__rt_panic", 0)
            emitted = true
        }
        if self.switch >= 0 && !self.asm.is_bound(self.switch) {
            // With RAX = where to note the stack pointer of the task that
            // stops, RCX = the stack pointer of the one that goes on. What a
            // function may rely on after a call is saved on the stack of
            // the first and found again on the stack of the second, which
            // returns to wherever it called this from.
            self.asm.bind(self.switch)
            var saved = [RBP, RBX, R12, R13, R14, RSI, RDI]
            for r in saved {
                self.asm.push(r)
            }
            self.asm.store(RAX, 0, RSP)
            self.asm.mov(RSP, RCX)
            for r in saved.reverse() {
                self.asm.pop(r)
            }
            self.asm.ret()
            emitted = true
        }
        if self.fault_entry >= 0 && !self.asm.is_bound(self.fault_entry) {
            // The kernel calls this with a description of the fault in RSI;
            // the address that was touched is 16 bytes into it.
            self.asm.bind(self.fault_entry)
            self.asm.load(RAX, RSI, 16)
            self.asm.push(RAX)
            self.call_runtime("__rt_fault", 0)
            emitted = true
        }
        if self.task_entry >= 0 && !self.asm.is_bound(self.task_entry) {
            // A new task: call its function, then leave for good.
            self.asm.bind(self.task_entry)
            self.asm.load(RAX, R15, CURRENT_TASK)
            self.asm.load(R10, RAX, TASK_CLOSURE)
            self.asm.call_mem(R10, FIELDS)
            self.reload_floats()
            self.call_runtime("__rt_task_exit", 0)
            emitted = true
        }
        if self.index_oob >= 0 && !self.asm.is_bound(self.index_oob) {
            // Reached with the list in RCX and the index in RAX.
            self.asm.bind(self.index_oob)
            self.asm.push(RCX)
            self.asm.push(RAX)
            self.call_runtime("__rt_index_panic", 0)
            emitted = true
        }
        return emitted
    }

    fn div_zero_label(self) -> int {
        if self.div_zero < 0 {
            self.div_zero = self.asm.new_label()
        }
        return self.div_zero
    }

    fn index_oob_label(self) -> int {
        if self.index_oob < 0 {
            self.index_oob = self.asm.new_label()
        }
        return self.index_oob
    }

    // ---- variables ----

    fn lookup(self, name: string) -> [VarRef] {
        var s = self.scopes.len() - 1
        while s >= 0 {
            var scope = self.scopes[s]
            var i = scope.len() - 1
            while i >= 0 {
                var v = scope[i]
                if v.name == name {
                    return [VarRef{loc: v.loc, is_ref: v.is_ref, owned: v.owned}]
                }
                i -= 1
            }
            s -= 1
        }
        if self.globals.has(name) {
            var global = self.globals[name]
            return [VarRef{loc: Loc.Global(global.offset), is_ref: is_ref(global.ty), owned: true}]
        }
        return []
    }

    // The variable `e` names, if it is a local one (a parameter included).
    fn local(self, e: ast.Expr) -> [VarRef] {
        match e.kind {
            Ident(name) {
                for v in self.lookup(name) {
                    match v.loc {
                        Global(_) {
                        }
                        else {
                            return [v]
                        }
                    }
                }
            }
            else {
            }
        }
        return []
    }

    // The home of a variable: the register it was planned in, or a new frame slot.
    fn home(self, key: int) -> Loc {
        if self.regs.has(key) {
            return Loc.Reg(self.regs[key])
        }
        self.slots += 1
        var offset = -8 * self.slots
        if self.float_regs.has(key) {
            self.in_xmm[offset] = self.float_regs[key]
        }
        return Loc.Frame(offset)
    }

    // If `e` is a float field of a struct held by a local variable: the
    // register that holds the struct (loaded into `scratch` if need be)
    // and the offset of the field, to compute with it where it is.
    fn float_field(self, e: ast.Expr, scratch: int) -> [int] {
        match e.kind {
            Field(obj, name, _, _) {
                if self.ty(e) != checker.Type.Float {
                    return []
                }
                var var_ref = self.local(obj)
                if var_ref.len() == 0 {
                    return []
                }
                var offset = self.field_offset(obj, name)
                if offset.len() == 0 {
                    return []
                }
                return [self.object_reg(var_ref[0].loc, scratch), offset[0]]
            }
            else {
                return []
            }
        }
    }

    fn scope_push(self, v: Var) {
        self.scopes[self.scopes.len() - 1].push(v)
    }

    fn declare(self, name: string, key: int, ty: checker.Type) -> Loc {
        var loc = self.home(key)
        var reference = is_ref(ty)
        self.scope_push(Var{name: name, loc: loc, is_ref: reference, owned: reference})
        return loc
    }

    fn load_loc(self, dst: int, loc: Loc) {
        match loc {
            Reg(r) {
                self.asm.mov(dst, r)
            }
            Frame(offset) {
                self.asm.load(dst, RBP, offset)
            }
            Global(offset) {
                self.asm.load(dst, R15, offset)
            }
        }
    }

    fn store_loc(self, loc: Loc, src: int) {
        match loc {
            Reg(r) {
                self.asm.mov(r, src)
            }
            Frame(offset) {
                self.asm.store(RBP, offset, src)
                if self.in_xmm.has(offset) {
                    self.asm.movq_in(self.in_xmm[offset], src)
                }
            }
            Global(offset) {
                self.asm.store(R15, offset, src)
            }
        }
    }

    // After a call: the float registers may have been used for something
    // else, so the variables kept in them are read again from their slots.
    fn reload_floats(self) {
        for offset in self.in_xmm.keys().sort() {
            self.asm.sse_load(SSE_MOV, self.in_xmm[offset], RBP, offset)
        }
    }

    fn load_operand(self, dst: int, operand: Operand) {
        match operand {
            Imm(v) {
                self.asm.mov_imm(dst, v)
            }
            At(loc) {
                self.load_loc(dst, loc)
            }
        }
    }

    // `dst = dst op operand`
    fn operand_alu(self, op: int, dst: int, operand: Operand) {
        match operand {
            Imm(v) {
                self.asm.alu_imm(op, dst, v)
            }
            At(loc) {
                match loc {
                    Reg(r) {
                        self.asm.alu(op, dst, r)
                    }
                    Frame(offset) {
                        self.asm.alu_load(op, dst, RBP, offset)
                    }
                    Global(offset) {
                        self.asm.alu_load(op, dst, R15, offset)
                    }
                }
            }
        }
    }

    // If `e` is an integer or boolean that needs no computation: a small
    // constant or a variable.
    fn simple(self, e: ast.Expr) -> [Operand] {
        match e.kind {
            Int(n) {
                if n >= -2147483648 && n <= 2147483647 {
                    return [Operand.Imm(n)]
                }
            }
            Bool(b) {
                if b {
                    return [Operand.Imm(1)]
                }
                return [Operand.Imm(0)]
            }
            Ident(name) {
                for v in self.lookup(name) {
                    if !v.is_ref {
                        return [Operand.At(v.loc)]
                    }
                }
            }
            Call(_, args) {
                var name = self.builtin_name(e)
                // The runtime's state has a register of its own.
                if name == "__state" {
                    return [Operand.At(Loc.Reg(R15))]
                }
                // The address of a string held by a local variable is that variable.
                if name == "__str_ptr" {
                    for v in self.local(args[0]) {
                        return [Operand.At(v.loc)]
                    }
                }
            }
            else {
            }
        }
        return []
    }

    // Evaluates `e`, an integer or a boolean, straight into a variable.
    fn expr_into(self, e: ast.Expr, loc: Loc) {
        match loc {
            Frame(offset) {
                if self.in_xmm.has(offset) {
                    // A float variable with a register: computed there, and
                    // written to its slot as well.
                    self.float(e)
                    self.asm.sse(SSE_MOV, self.in_xmm[offset], XMM0)
                    self.asm.sse_store(RBP, offset, XMM0)
                    return
                }
            }
            else {
            }
        }
        var operand = self.simple(e)
        if operand.len() > 0 {
            match loc {
                Reg(r) {
                    self.load_operand(r, operand[0])
                    return
                }
                Frame(offset) {
                    match operand[0] {
                        Imm(v) {
                            self.asm.store_imm(RBP, offset, v)
                            return
                        }
                        else {
                        }
                    }
                }
                Global(offset) {
                    match operand[0] {
                        Imm(v) {
                            self.asm.store_imm(R15, offset, v)
                            return
                        }
                        else {
                        }
                    }
                }
            }
        }
        self.expr(e)
        self.store_loc(loc, RAX)
    }

    // Pushes `e`, an integer or a boolean.
    fn push_value(self, e: ast.Expr) {
        var operand = self.simple(e)
        if operand.len() == 0 {
            self.expr(e)
            self.asm.push(RAX)
            return
        }
        match operand[0] {
            Imm(v) {
                self.asm.push_imm(v)
            }
            At(loc) {
                match loc {
                    Reg(r) {
                        self.asm.push(r)
                    }
                    Frame(offset) {
                        self.asm.push_mem(RBP, offset)
                    }
                    Global(offset) {
                        self.asm.push_mem(R15, offset)
                    }
                }
            }
        }
    }

    // ---- reference counting ----

    // Adds one reference to the object whose address is in `r`. Changes no register.
    fn retain(self, r: int) {
        self.asm.cmp32_mem(r, COUNT, 0)
        // Constants are never counted.
        var constant = self.asm.jcc_short(CC_L)
        self.asm.inc32_mem(r, COUNT)
        self.asm.bind_short(constant)
    }

    // Drops one reference to the object in RAX, destroying it if it was the
    // last. Every scratch register may change.
    fn release_rax(self) {
        self.asm.cmp32_mem(RAX, COUNT, 1)
        var constant = self.asm.jcc_short(CC_L)
        var last = self.asm.jcc_short(CC_E)
        self.asm.dec32_mem(RAX, COUNT)
        var done = self.asm.jmp_short()
        self.asm.bind_short(last)
        self.asm.push(RAX)
        self.call_runtime("__rt_destroy", 1)
        self.asm.bind_short(done)
        self.asm.bind_short(constant)
    }

    // With a result in RAX and an owned reference on top of the stack:
    // releases that reference and keeps the result.
    fn release_saved(self) {
        self.asm.pop(RCX)
        self.asm.push(RAX)
        self.asm.mov(RAX, RCX)
        self.release_rax()
        self.asm.pop(RAX)
    }

    // The owned references of the scopes from `first` on, innermost first
    // (`except`: one location to leave out).
    fn owned_refs(self, first: int, except: [Loc]) -> [Loc] {
        var out: [Loc] = []
        var s = self.scopes.len() - 1
        while s >= first {
            var scope = self.scopes[s]
            var i = scope.len() - 1
            while i >= 0 {
                var v = scope[i]
                if v.is_ref && v.owned && (except.len() == 0 || v.loc != except[0]) {
                    out.push(v.loc)
                }
                i -= 1
            }
            s -= 1
        }
        return out
    }

    // Releases the variables of the scopes from `first` on (they stay declared).
    fn release_scopes(self, first: int) {
        for loc in self.owned_refs(first, []) {
            self.load_loc(RAX, loc)
            self.release_rax()
        }
    }

    // After a call: releases the arguments that were temporary values
    // (`owned[i]` for the i-th pushed argument) and removes them all from the
    // stack. The result in RAX is preserved when `keep_result` is set, and
    // so is the error in RDX after a call that can fail (`keep_error`).
    fn drop_args(self, owned: [bool], keep_result: bool) {
        var keep_error = self.keep_error
        self.keep_error = false
        var n = owned.len()
        if n == 0 {
            return
        }
        if owned.contains(true) {
            var base = 0
            if keep_result {
                self.asm.push(RAX)
                base += 8
            }
            if keep_error {
                self.asm.push(RDX)
                base += 8
            }
            for i in 0..n {
                if owned[i] {
                    self.asm.load(RAX, RSP, base + 8 * (n - 1 - i))
                    self.release_rax()
                }
            }
            if keep_error {
                self.asm.pop(RDX)
            }
            if keep_result {
                self.asm.pop(RAX)
            }
        }
        self.asm.alu_imm(ALU_ADD, RSP, 8 * n)
    }

    // ---- functions ----

    fn function(self, key: string) {
        var item = self.items[key]
        var body = item.body
        var params = item.params
        for p in params {
            self.check_type(p.ty, p.start, p.end)
        }
        self.check_type(item.ret, item.start, item.end)
        self.fallible = item.fallible

        var names: [plan.PlanParam] = []
        for p in params {
            names.push(plan.PlanParam{name: p.name, key: p.key, float: p.ty == checker.Type.Float})
        }
        var the_plan = plan.plan(body, names, variable_regs(), float_regs(), self.an.types)
        self.float_regs = the_plan.floats
        self.in_xmm = {}
        var saved: [int] = []
        for k in the_plan.regs.keys() {
            saved.push(the_plan.regs[k])
        }
        saved = saved.sort()
        self.regs = the_plan.regs
        self.slots = saved.len()
        self.loops = []
        var epilogue = self.asm.new_label()
        self.epilogue = epilogue

        self.asm.bind(self.labels[key])
        self.asm.push(RBP)
        self.asm.mov(RBP, RSP)
        var frame_size_at = self.asm.alu_imm32_patchable(ALU_SUB, RSP, 0)
        for k in 0..saved.len() {
            self.asm.store(RBP, -8 * (k + 1), saved[k])
        }

        // The first argument was pushed first, so it is the farthest from RBP.
        var count = params.len()
        var scope: [Var] = []
        // A lambda finds its closure in R10. What it captured is copied out
        // of it; the closure, which the caller holds, keeps all of it alive.
        for i in 0..item.captures.len() {
            var c = item.captures[i]
            self.slots += 1
            var slot = -8 * self.slots
            self.asm.load(RAX, R10, FIELDS + 8 + 8 * i)
            self.asm.store(RBP, slot, RAX)
            scope.push(Var{name: c.name, loc: Loc.Frame(slot), is_ref: is_ref(c.ty), owned: false})
        }
        for i in 0..count {
            var p = params[i]
            var pushed_at = 16 + 8 * (count - 1 - i)
            // A parameter is borrowed from the caller, unless the function
            // assigns to it: then it needs a reference of its own.
            var reference = is_ref(p.ty)
            var owned = reference && the_plan.assigned.has(p.key)
            var loc = Loc.Frame(pushed_at)
            if self.regs.has(p.key) {
                var r = self.regs[p.key]
                self.asm.load(r, RBP, pushed_at)
                loc = Loc.Reg(r)
            } else if owned {
                // It also needs a place of its own: after the call, the
                // caller looks at what it pushed to release temporary values.
                self.slots += 1
                var slot = -8 * self.slots
                self.asm.load(RAX, RBP, pushed_at)
                self.asm.store(RBP, slot, RAX)
                loc = Loc.Frame(slot)
            }
            if owned {
                self.load_loc(RAX, loc)
                self.retain(RAX)
            }
            match loc {
                Frame(offset) {
                    if self.float_regs.has(p.key) {
                        var x = self.float_regs[p.key]
                        self.in_xmm[offset] = x
                        self.asm.sse_load(SSE_MOV, x, RBP, offset)
                    }
                }
                else {
                }
            }
            scope.push(Var{name: p.name, loc: loc, is_ref: reference, owned: owned})
        }
        self.scopes = [scope]

        var last = body.stmts.len() - 1
        for i in 0..body.stmts.len() {
            self.at_tail = i == last
            self.stmt(body.stmts[i])
        }
        self.at_tail = false
        if !leaves(body) {
            self.release_scopes(0)
        }
        if item.fallible {
            // Reaching the end means success.
            self.asm.mov_imm(RDX, 0)
        }

        self.asm.bind(epilogue)
        for k in 0..saved.len() {
            self.asm.load(saved[k], RBP, -8 * (k + 1))
        }
        self.asm.mov(RSP, RBP)
        self.asm.pop(RBP)
        self.asm.ret()
        self.asm.patch32(frame_size_at, self.slots * 8)
        self.scopes = []
        self.regs = {}
        self.float_regs = {}
        self.in_xmm = {}
    }

    // ---- statements ----

    fn block(self, block: ast.Block) {
        var empty: [Var] = []
        self.scopes.push(empty)
        for stmt in block.stmts {
            self.stmt(stmt)
        }
        if !leaves(block) {
            self.release_scopes(self.scopes.len() - 1)
        }
        self.scopes.remove(self.scopes.len() - 1)
    }

    fn stmt(self, stmt: ast.Stmt) {
        var tail = self.at_tail
        self.at_tail = false
        match stmt.kind {
            Match(_, _, _) {
                panic("`match` is rewritten by desugar before this pass")
            }
            Let(name, name_start, _, _, _, init) {
                var ty = self.ty(init)
                if is_catch(init) {
                    // The variable only exists once one of the two paths gave it a value.
                    var loc = self.home(plan.var_key(name_start, plan.NAMED))
                    self.catch_expr(init, Sink.Var(loc))
                    var reference = is_ref(ty)
                    self.scope_push(Var{name: name, loc: loc, is_ref: reference, owned: reference})
                } else if is_ref(ty) {
                    self.expr(init)
                    var loc = self.declare(name, plan.var_key(name_start, plan.NAMED), ty)
                    self.store_loc(loc, RAX)
                } else {
                    // The value is computed before the name exists: it may
                    // mention an outer variable of the same name.
                    var loc = self.home(plan.var_key(name_start, plan.NAMED))
                    self.expr_into(init, loc)
                    self.scope_push(Var{name: name, loc: loc, is_ref: false, owned: false})
                }
            }
            Assign(target, op, value) {
                if is_catch(value) {
                    // After lowering, the target of such an assignment is a plain variable.
                    match target.kind {
                        Ident(name) {
                            var found = self.lookup(name)
                            if found.len() > 0 {
                                self.catch_expr(value, Sink.Assign(found[0]))
                            } else {
                                self.unsupported(target.start, target.end, "assignments to this name")
                            }
                        }
                        else {
                            self.unsupported(target.start, target.end, "this use of `catch`")
                        }
                    }
                } else {
                    self.assign(target, op, value)
                }
            }
            Expr(e) {
                if is_catch(e) {
                    self.catch_expr(e, Sink.Discard)
                } else {
                    self.expr(e)
                    if is_ref(self.ty(e)) {
                        self.release_rax()
                    }
                }
            }
            If(cond, then, els) {
                var otherwise = self.asm.new_label()
                self.cond_jump(cond, otherwise, false)
                self.block(then)
                if els.len() > 0 {
                    var end = self.asm.new_label()
                    if !leaves(then) {
                        self.asm.jmp(end)
                    }
                    self.asm.bind(otherwise)
                    self.stmt(els[0])
                    self.asm.bind(end)
                } else {
                    self.asm.bind(otherwise)
                }
            }
            While(cond, body) {
                // The test sits at the bottom: one jump per turn instead of two.
                var top = self.asm.new_label()
                var check = self.asm.new_label()
                var end = self.asm.new_label()
                var forever = is_bool(cond, true)
                if !forever {
                    self.asm.jmp(check)
                }
                self.asm.bind(top)
                var depth = self.scopes.len()
                self.loops.push(Loop{next: check, end: end, continue_from: depth, break_from: depth})
                self.block(body)
                self.loops.remove(self.loops.len() - 1)
                self.asm.bind(check)
                if forever {
                    self.asm.jmp(top)
                } else {
                    self.cond_jump(cond, top, true)
                }
                self.asm.bind(end)
            }
            For(name, name_start, name_end, iter, body) {
                match self.ty(iter) {
                    Range {
                        self.for_range(name, name_start, iter, body)
                    }
                    List(elem) {
                        self.for_list(name, name_start, iter, body, elem)
                    }
                    Map(key, _) {
                        self.for_map(name, name_start, iter, body, key)
                    }
                    Str {
                        self.for_str(name, name_start, iter, body)
                    }
                    Chan(elem) {
                        self.for_chan(name, name_start, iter, body, elem)
                    }
                    else {
                        self.unsupported(iter.start, iter.end, "loops over this type")
                    }
                }
            }
            Return(value) {
                if value.len() > 0 && is_catch(value[0]) {
                    self.catch_expr(value[0], Sink.Return)
                } else {
                    // Returning an owned local variable hands its reference over
                    // to the caller instead of making a new one and dropping the old.
                    var moved: [Loc] = []
                    for v in value {
                        var found = self.local(v)
                        if found.len() > 0 && found[0].is_ref && found[0].owned {
                            self.load_loc(RAX, found[0].loc)
                            moved = [found[0].loc]
                        } else {
                            self.expr(v)
                        }
                    }
                    self.finish_return(value.len() > 0, moved, tail)
                }
            }
            Fail(value) {
                // The error (a string) goes to the caller in RDX.
                var moved: [Loc] = []
                var found = self.local(value)
                if found.len() > 0 && found[0].is_ref && found[0].owned {
                    self.load_loc(RAX, found[0].loc)
                    moved = [found[0].loc]
                } else {
                    self.expr(value)
                }
                self.leave_with_error(RAX, moved)
            }
            Break {
                var l = self.loops[self.loops.len() - 1]
                self.release_scopes(l.break_from)
                self.asm.jmp(l.end)
            }
            Continue {
                var l = self.loops[self.loops.len() - 1]
                self.release_scopes(l.continue_from)
                self.asm.jmp(l.next)
            }
            Block(body) {
                self.block(body)
            }
            Fork(_) {
                self.unsupported(stmt.start, stmt.end, "`fork` blocks")
            }
            Send(channel, value) {
                // The value moves into the channel.
                var owned = [self.push_arg(channel), false]
                self.expr(value)
                self.asm.push(RAX)
                self.call_runtime("__rt_chan_send", 0)
                self.drop_args(owned, false)
            }
        }
    }

    // Ends the function normally. The returned value, if any, is in RAX;
    // `moved` is the variable it was taken from (and that must not be released).
    fn finish_return(self, has_value: bool, moved: [Loc], tail: bool) {
        var pending = self.owned_refs(0, moved)
        if pending.len() > 0 {
            if has_value {
                self.asm.push(RAX)
            }
            for loc in pending {
                self.load_loc(RAX, loc)
                self.release_rax()
            }
            if has_value {
                self.asm.pop(RAX)
            }
        }
        // The last statement of a function simply reaches its end.
        if !tail {
            if self.fallible {
                self.asm.mov_imm(RDX, 0)
            }
            self.asm.jmp(self.epilogue)
        }
    }

    // Ends the function with the error held in `error` (RAX or RDX).
    fn leave_with_error(self, error: int, moved: [Loc]) {
        var pending = self.owned_refs(0, moved)
        if pending.len() > 0 {
            self.asm.push(error)
            for loc in pending {
                self.load_loc(RAX, loc)
                self.release_rax()
            }
            self.asm.pop(RDX)
        } else {
            self.asm.mov(RDX, error)
        }
        self.asm.jmp(self.epilogue)
    }

    // `call() catch err { ... }`: the call's value goes to `sink`; if the
    // call fails, the block runs with the error, and may provide a value
    // instead (its last expression) or leave.
    fn catch_expr(self, e: ast.Expr, sink: Sink) {
        match e.kind {
            Catch(call, name, name_start, _, body) {
                var ty = self.ty(e)
                var has_value = self.an.catch_values.has(e.id)
                var handler = self.asm.new_label()
                var done = self.asm.new_label()
                self.expr(call)
                self.asm.test(RDX, RDX)
                self.asm.jcc(CC_NE, handler)
                self.sink(sink, ty)
                if sink != Sink.Return {
                    self.asm.jmp(done)
                }

                self.asm.bind(handler)
                var empty: [Var] = []
                self.scopes.push(empty)
                var error = self.declare(name, plan.var_key(name_start, plan.NAMED), checker.Type.Error)
                self.store_loc(error, RDX)
                var scope = self.scopes.len() - 1
                var count = body.stmts.len()
                var value: [ast.Expr] = []
                if has_value && count > 0 {
                    match body.stmts[count - 1].kind {
                        Expr(last) {
                            value = [last]
                            count -= 1
                        }
                        else {
                        }
                    }
                }
                for i in 0..count {
                    self.stmt(body.stmts[i])
                }
                if value.len() > 0 {
                    // The block's last expression stands in for the call's value.
                    self.expr(value[0])
                    self.asm.push(RAX)
                    self.release_scopes(scope)
                    self.asm.pop(RAX)
                    self.scopes.remove(self.scopes.len() - 1)
                    self.sink(sink, ty)
                } else {
                    if !leaves(body) {
                        self.release_scopes(scope)
                    }
                    self.scopes.remove(self.scopes.len() - 1)
                    // `return call() catch err { ... }` with nothing to return.
                    if sink == Sink.Return && !leaves(body) {
                        self.finish_return(false, [], false)
                    }
                }
                self.asm.bind(done)
            }
            else {
            }
        }
    }

    // Sends the value in RAX where a `catch` expression's value goes.
    fn sink(self, sink: Sink, ty: checker.Type) {
        match sink {
            Var(loc) {
                self.store_loc(loc, RAX)
            }
            Assign(v) {
                if v.is_ref {
                    self.load_loc(RCX, v.loc)
                    self.store_loc(v.loc, RAX)
                    self.asm.mov(RAX, RCX)
                    self.release_rax()
                } else {
                    self.store_loc(v.loc, RAX)
                }
            }
            Return {
                self.finish_return(ty != checker.Type.Void, [], false)
            }
            Discard {
                if is_ref(ty) {
                    self.release_rax()
                }
            }
        }
    }

    // Adds one to a counter, where it is.
    fn increment(self, loc: Loc) {
        match loc {
            Reg(r) {
                self.asm.alu_imm(ALU_ADD, r, 1)
            }
            Frame(offset) {
                self.asm.alu_store_imm(ALU_ADD, RBP, offset, 1)
            }
            Global(offset) {
                self.asm.alu_store_imm(ALU_ADD, R15, offset, 1)
            }
        }
    }

    fn for_range(self, name: string, at: int, iter: ast.Expr, body: ast.Block) {
        match iter.kind {
            Range(lo, hi) {
                var top = self.asm.new_label()
                var next = self.asm.new_label()
                var check = self.asm.new_label()
                var end = self.asm.new_label()
                var empty: [Var] = []
                self.scopes.push(empty)
                // Both bounds are computed once, before the loop variable exists.
                var counter = self.home(plan.var_key(at, plan.NAMED))
                self.expr_into(lo, counter)
                var limit = Operand.Imm(0)
                var constant = false
                for operand in self.simple(hi) {
                    match operand {
                        Imm(v) {
                            limit = Operand.Imm(v)
                            constant = true
                        }
                        else {
                        }
                    }
                }
                if !constant {
                    var loc = self.home(plan.var_key(at, plan.COUNTER))
                    self.expr_into(hi, loc)
                    limit = Operand.At(loc)
                }
                self.scope_push(Var{name: name, loc: counter, is_ref: false, owned: false})

                self.asm.jmp(check)
                self.asm.bind(top)
                var depth = self.scopes.len()
                self.loops.push(Loop{next: next, end: end, continue_from: depth, break_from: depth})
                self.block(body)
                self.loops.remove(self.loops.len() - 1)
                self.asm.bind(next)
                self.increment(counter)
                self.asm.bind(check)
                match counter {
                    Reg(r) {
                        self.operand_alu(ALU_CMP, r, limit)
                    }
                    else {
                        self.load_loc(RAX, counter)
                        self.operand_alu(ALU_CMP, RAX, limit)
                    }
                }
                self.asm.jcc(CC_L, top)
                self.asm.bind(end)
                self.scopes.remove(self.scopes.len() - 1)
            }
            else {
                self.unsupported(iter.start, iter.end, "ranges stored in variables")
            }
        }
    }

    fn for_list(self, name: string, at: int, iter: ast.Expr, body: ast.Block, elem: checker.Type) {
        var top = self.asm.new_label()
        var next = self.asm.new_label()
        var check = self.asm.new_label()
        var end = self.asm.new_label()
        // Outer scope: the list (kept alive for the whole loop) and the position in it.
        var outer: [Var] = []
        self.scopes.push(outer)
        self.expr(iter)
        var list = self.declare("<list>", plan.var_key(at, plan.SUBJECT), self.ty(iter))
        self.store_loc(list, RAX)
        var index = self.home(plan.var_key(at, plan.COUNTER))
        self.set_zero(index)
        self.asm.jmp(check)

        self.asm.bind(top)
        // Inner scope: the loop variable, released after each turn.
        var inner: [Var] = []
        self.scopes.push(inner)
        self.load_loc(RCX, list)
        self.asm.load(RCX, RCX, LIST_DATA)
        self.load_loc(RAX, index)
        self.asm.load_indexed(RAX, RCX, RAX)
        if is_ref(elem) {
            self.retain(RAX)
        }
        var item = self.declare(name, plan.var_key(at, plan.NAMED), elem)
        self.store_loc(item, RAX)

        var depth = self.scopes.len()
        self.loops.push(Loop{next: next, end: end, continue_from: depth, break_from: depth - 1})
        self.block(body)
        self.loops.remove(self.loops.len() - 1)

        self.asm.bind(next)
        self.release_scopes(depth - 1)
        self.scopes.remove(self.scopes.len() - 1)
        self.increment(index)
        // The length is read again on every turn, so the body may change the list.
        self.asm.bind(check)
        self.load_loc(RCX, list)
        match index {
            Reg(r) {
                self.asm.alu_load(ALU_CMP, r, RCX, LIST_LEN)
            }
            else {
                self.load_loc(RAX, index)
                self.asm.alu_load(ALU_CMP, RAX, RCX, LIST_LEN)
            }
        }
        self.asm.jcc(CC_L, top)

        self.asm.bind(end)
        self.release_scopes(self.scopes.len() - 1)
        self.scopes.remove(self.scopes.len() - 1)
    }

    // Sets a counter to zero, where it is.
    fn set_zero(self, loc: Loc) {
        match loc {
            Reg(r) {
                self.asm.mov_imm(r, 0)
            }
            Frame(offset) {
                self.asm.store_imm(RBP, offset, 0)
            }
            Global(offset) {
                self.asm.store_imm(R15, offset, 0)
            }
        }
    }

    // Jumps to `target` when `cond` is `when`; falls through otherwise.
    fn cond_jump(self, cond: ast.Expr, target: int, when: bool) {
        match cond.kind {
            Bool(b) {
                if b == when {
                    self.asm.jmp(target)
                }
                return
            }
            Unary(op, inner) {
                if op == ast.UnOp.Not {
                    self.cond_jump(inner, target, !when)
                    return
                }
            }
            Binary(op, lhs, rhs) {
                if op == ast.BinOp.And {
                    if when {
                        var skip = self.asm.new_label()
                        self.cond_jump(lhs, skip, false)
                        self.cond_jump(rhs, target, true)
                        self.asm.bind(skip)
                    } else {
                        self.cond_jump(lhs, target, false)
                        self.cond_jump(rhs, target, false)
                    }
                    return
                }
                if op == ast.BinOp.Or {
                    if when {
                        self.cond_jump(lhs, target, true)
                        self.cond_jump(rhs, target, true)
                    } else {
                        var skip = self.asm.new_label()
                        self.cond_jump(lhs, skip, true)
                        self.cond_jump(rhs, target, false)
                        self.asm.bind(skip)
                    }
                    return
                }
                if is_comparison(op) && int_like(self.ty(lhs)) && int_like(self.ty(rhs)) {
                    var cc = self.compare(op, lhs, rhs)
                    if !when {
                        cc = cc ^ 1
                    }
                    self.asm.jcc(cc, target)
                    return
                }
                if is_comparison(op) && self.ty(lhs) == checker.Type.Float {
                    var cc = self.float_compare(op, lhs, rhs)
                    if (cc == CC_E && when) || (cc == CC_NE && !when) {
                        // "Equal" needs both to be numbers; "different" is everything else.
                        var unordered = self.asm.jcc_short(CC_P)
                        self.asm.jcc(CC_E, target)
                        self.asm.bind_short(unordered)
                    } else if (cc == CC_E && !when) || (cc == CC_NE && when) {
                        self.asm.jcc(CC_NE, target)
                        self.asm.jcc(CC_P, target)
                    } else if when {
                        self.asm.jcc(cc, target)
                    } else {
                        self.asm.jcc(cc ^ 1, target)
                    }
                    return
                }
            }
            else {
            }
        }
        var r = -1
        for operand in self.simple(cond) {
            r = operand_reg(operand)
        }
        if r >= 0 {
            self.asm.test(r, r)
        } else {
            self.expr(cond)
            self.asm.test(RAX, RAX)
        }
        if when {
            self.asm.jcc(CC_NE, target)
        } else {
            self.asm.jcc(CC_E, target)
        }
    }

    // Compares two integers (or booleans) and returns the condition under
    // which `lhs op rhs` holds.
    fn compare(self, op: ast.BinOp, lhs: ast.Expr, rhs: ast.Expr) -> int {
        var cc = cc_of(op)
        var left = self.simple(lhs)
        var right = self.simple(rhs)
        if right.len() > 0 {
            if left.len() > 0 && operand_reg(left[0]) >= 0 {
                self.operand_alu(ALU_CMP, operand_reg(left[0]), right[0])
                return cc
            }
            self.expr(lhs)
            self.operand_alu(ALU_CMP, RAX, right[0])
            return cc
        }
        // The left side is a constant or a local variable: computing the
        // right side first cannot change it.
        if left.len() > 0 && !is_global_operand(left[0]) {
            self.expr(rhs)
            self.operand_alu(ALU_CMP, RAX, left[0])
            return swap_cc(cc)
        }
        self.expr(lhs)
        self.asm.push(RAX)
        self.expr(rhs)
        self.asm.mov(RCX, RAX)
        self.asm.pop(RAX)
        self.asm.alu(ALU_CMP, RAX, RCX)
        return cc
    }

    // ---- assignments ----

    fn assign(self, target: ast.Expr, op: ast.AssignOp, value: ast.Expr) {
        var ty = self.ty(target)
        var bin: [ast.BinOp] = []
        match op {
            Set {
            }
            Add {
                bin = [ast.BinOp.Add]
            }
            Sub {
                bin = [ast.BinOp.Sub]
            }
            Mul {
                bin = [ast.BinOp.Mul]
            }
            Div {
                bin = [ast.BinOp.Div]
            }
        }
        match target.kind {
            Ident(name) {
                var found = self.lookup(name)
                if found.len() > 0 {
                    self.assign_variable(target, name, found[0], ty, bin, value)
                } else {
                    self.unsupported(target.start, target.end, "assignments to this name")
                }
            }
            Field(obj, name, _, _) {
                var offset = self.field_offset(obj, name)
                if offset.len() > 0 {
                    self.assign_field(obj, offset[0], ty, bin, value)
                } else {
                    self.unsupported(target.start, target.end, "assignments to this kind of field")
                }
            }
            Index(obj, index) {
                match self.ty(obj) {
                    List(_) {
                        self.assign_element(obj, index, ty, bin, value)
                    }
                    Map(_, _) {
                        self.assign_entry(obj, index, ty, bin, value)
                    }
                    else {
                        self.unsupported(target.start, target.end, "assignments to this kind of expression")
                    }
                }
            }
            else {
                self.unsupported(target.start, target.end, "assignments to this kind of expression")
            }
        }
    }

    fn assign_variable(self, target: ast.Expr, name: string, v: VarRef, ty: checker.Type, bin: [ast.BinOp], value: ast.Expr) {
        if !is_ref(ty) {
            if bin.len() == 0 {
                self.expr_into(value, v.loc)
                return
            }
            var op = bin[0]
            var additive = op == ast.BinOp.Add || op == ast.BinOp.Sub
            var alu = ALU_SUB
            if op == ast.BinOp.Add {
                alu = ALU_ADD
            }
            var operand = self.simple(value)
            if additive && operand.len() > 0 {
                // `x += 1` and the like work on the variable where it is.
                var base = R15
                var offset = 0
                match v.loc {
                    Reg(r) {
                        self.operand_alu(alu, r, operand[0])
                        return
                    }
                    Frame(o) {
                        base = RBP
                        offset = o
                    }
                    Global(o) {
                        offset = o
                    }
                }
                match operand[0] {
                    Imm(n) {
                        self.asm.alu_store_imm(alu, base, offset, n)
                    }
                    At(_) {
                        var r = operand_reg(operand[0])
                        if r >= 0 {
                            self.asm.alu_store(alu, base, offset, r)
                        } else {
                            self.load_operand(RAX, operand[0])
                            self.asm.alu_store(alu, base, offset, RAX)
                        }
                    }
                }
                return
            }
            if additive && !is_global(v.loc) {
                // A local variable cannot change while the value is computed.
                self.expr(value)
                match v.loc {
                    Reg(r) {
                        self.asm.alu(alu, r, RAX)
                    }
                    Frame(o) {
                        self.asm.alu_store(alu, RBP, o, RAX)
                    }
                    Global(o) {
                        self.asm.alu_store(alu, R15, o, RAX)
                    }
                }
                return
            }
            self.arith(op, target, value)
            self.store_loc(v.loc, RAX)
            return
        }

        // `s += x` and `s = s + x` on a local string: its reference is given
        // to the runtime, which extends the string in place when it can.
        if ty == checker.Type.Str && !is_global(v.loc) {
            var piece: [ast.Expr] = []
            if bin.len() > 0 {
                if bin[0] == ast.BinOp.Add {
                    piece = [value]
                }
            } else {
                match value.kind {
                    Binary(op, lhs, rhs) {
                        if op == ast.BinOp.Add {
                            match lhs.kind {
                                Ident(n) {
                                    if n == name {
                                        piece = [rhs]
                                    }
                                }
                                else {
                                }
                            }
                        }
                    }
                    else {
                    }
                }
            }
            if piece.len() > 0 {
                self.push_loc(v.loc)
                var owned = self.operand(piece[0])
                self.asm.push(RAX)
                self.call_runtime("__rt_append", 0)
                self.store_loc(v.loc, RAX)
                if owned {
                    self.asm.load(RAX, RSP, 0)
                    self.release_rax()
                }
                self.asm.alu_imm(ALU_ADD, RSP, 16)
                return
            }
        }

        // Compute the new value, store it, then let go of the one it replaces.
        if bin.len() > 0 {
            self.string_binary(bin[0], target, value)
        } else {
            self.expr(value)
        }
        self.load_loc(RCX, v.loc)
        self.store_loc(v.loc, RAX)
        self.asm.mov(RAX, RCX)
        self.release_rax()
    }

    // Pushes what a variable holds.
    fn push_loc(self, loc: Loc) {
        match loc {
            Reg(r) {
                self.asm.push(r)
            }
            Frame(offset) {
                self.asm.push_mem(RBP, offset)
            }
            Global(offset) {
                self.asm.push_mem(R15, offset)
            }
        }
    }

    fn assign_field(self, obj: ast.Expr, offset: int, ty: checker.Type, bin: [ast.BinOp], value: ast.Expr) {
        var reference = is_ref(ty)
        if !reference {
            for v in self.local(obj) {
                // The object is in a variable: write (or update) the field in place.
                var additive = bin.len() == 0 || bin[0] == ast.BinOp.Add || bin[0] == ast.BinOp.Sub
                var operand = self.simple(value)
                if additive && operand.len() > 0 {
                    var base = self.object_reg(v.loc, RCX)
                    var source = RAX
                    match operand[0] {
                        Imm(n) {
                            if bin.len() == 0 {
                                self.asm.store_imm(base, offset, n)
                            } else if bin[0] == ast.BinOp.Add {
                                self.asm.alu_store_imm(ALU_ADD, base, offset, n)
                            } else {
                                self.asm.alu_store_imm(ALU_SUB, base, offset, n)
                            }
                            return
                        }
                        At(_) {
                            var r = operand_reg(operand[0])
                            if r >= 0 {
                                source = r
                            } else {
                                self.load_operand(RAX, operand[0])
                            }
                        }
                    }
                    if bin.len() == 0 {
                        self.asm.store(base, offset, source)
                    } else if bin[0] == ast.BinOp.Add {
                        self.asm.alu_store(ALU_ADD, base, offset, source)
                    } else {
                        self.asm.alu_store(ALU_SUB, base, offset, source)
                    }
                    return
                }
                if bin.len() == 0 {
                    self.expr(value)
                    var base = self.object_reg(v.loc, RCX)
                    self.asm.store(base, offset, RAX)
                    return
                }
                // The value runs no code of the program, so it cannot change
                // the field: it can be computed first.
                if self.is_pure(value) {
                    self.expr(value)
                    var op = bin[0]
                    if op == ast.BinOp.Add || op == ast.BinOp.Sub {
                        var alu = ALU_SUB
                        if op == ast.BinOp.Add {
                            alu = ALU_ADD
                        }
                        var base = self.object_reg(v.loc, RCX)
                        self.asm.alu_store(alu, base, offset, RAX)
                    } else {
                        self.asm.mov(RCX, RAX)
                        var base = self.object_reg(v.loc, R8)
                        self.asm.load(RAX, base, offset)
                        self.arith_rcx(op)
                        self.asm.store(base, offset, RAX)
                    }
                    return
                }
            }
        }

        // General case: the object waits on the stack.
        var owned = self.operand(obj)
        self.asm.push(RAX)
        if bin.len() > 0 && ty == checker.Type.Str {
            // The current text, kept alive while the new one is built.
            self.asm.load(RAX, RAX, offset)
            self.retain(RAX)
            self.asm.push(RAX)
            var piece_owned = self.operand(value)
            self.asm.push(RAX)
            self.call_runtime("__rt_concat", 0)
            self.drop_args([true, piece_owned], true)
        } else if bin.len() > 0 {
            self.asm.load(RAX, RAX, offset)
            self.asm.push(RAX)
            self.expr(value)
            self.asm.mov(RCX, RAX)
            self.asm.pop(RAX)
            self.arith_rcx(bin[0])
        } else {
            self.expr(value)
        }
        self.asm.load(RCX, RSP, 0)
        if reference {
            self.asm.load(RDX, RCX, offset)
        }
        self.asm.store(RCX, offset, RAX)
        if reference {
            self.asm.mov(RAX, RDX)
            self.release_rax()
        }
        self.asm.pop(RAX)
        if owned {
            self.release_rax()
        }
    }

    // A register holding the object of a local variable: the variable's own
    // register, or `scratch` after loading it.
    fn object_reg(self, loc: Loc, scratch: int) -> int {
        match loc {
            Reg(r) {
                return r
            }
            else {
                self.load_loc(scratch, loc)
                return scratch
            }
        }
    }

    fn assign_element(self, obj: ast.Expr, index: ast.Expr, ty: checker.Type, bin: [ast.BinOp], value: ast.Expr) {
        var reference = is_ref(ty)
        var list = self.local(obj)
        var position = self.simple(index)
        if !reference && list.len() > 0 && position.len() > 0 {
            // An integer list in a variable, at a simple position.
            if bin.len() == 0 {
                self.expr(value)
                self.asm.mov(RDX, RAX)
                self.load_loc(RCX, list[0].loc)
                self.load_operand(RAX, position[0])
                self.element_address()
                self.asm.store_indexed(RCX, RAX, RDX)
                return
            }
            // The value runs no code of the program, so it cannot change
            // the list: it can be computed first.
            var op = bin[0]
            if (op == ast.BinOp.Add || op == ast.BinOp.Sub) && self.is_pure(value) {
                self.expr(value)
                self.asm.mov(RDX, RAX)
                self.load_loc(RCX, list[0].loc)
                self.load_operand(RAX, position[0])
                self.element_address()
                self.asm.load_indexed(R8, RCX, RAX)
                if op == ast.BinOp.Add {
                    self.asm.alu(ALU_ADD, R8, RDX)
                } else {
                    self.asm.alu(ALU_SUB, R8, RDX)
                }
                self.asm.store_indexed(RCX, RAX, R8)
                return
            }
        }

        // General case: the list and the position wait on the stack.
        var owned = self.operand(obj)
        self.asm.push(RAX)
        self.expr(index)
        self.asm.push(RAX)
        if bin.len() > 0 {
            self.asm.load(RCX, RSP, 8)
            self.element_address()
            self.asm.load_indexed(RAX, RCX, RAX)
            if ty == checker.Type.Str {
                self.retain(RAX)
                self.asm.push(RAX)
                var piece_owned = self.operand(value)
                self.asm.push(RAX)
                self.call_runtime("__rt_concat", 0)
                self.drop_args([true, piece_owned], true)
            } else {
                self.asm.push(RAX)
                self.expr(value)
                self.asm.mov(RCX, RAX)
                self.asm.pop(RAX)
                self.arith_rcx(bin[0])
            }
        } else {
            self.expr(value)
        }
        self.asm.mov(RDX, RAX)
        self.asm.pop(RAX)
        self.asm.load(RCX, RSP, 0)
        // Checked again: computing the value may have changed the list.
        self.element_address()
        if reference {
            self.asm.load_indexed(R8, RCX, RAX)
        }
        self.asm.store_indexed(RCX, RAX, RDX)
        if reference {
            self.asm.mov(RAX, R8)
            self.release_rax()
        }
        self.asm.pop(RAX)
        if owned {
            self.release_rax()
        }
    }

    // ---- expressions: values ----

    // Evaluates `e` into RAX. A reference is owned by whoever asked for it.
    fn expr(self, e: ast.Expr) {
        var ty = self.ty(e)
        if !supported(ty) {
            self.unsupported(e.start, e.end, "values of type `" + checker.show(ty) + "`")
            return
        }
        if self.an.variants.has(e.id) {
            var v = self.an.variants[e.id]
            self.variant(e, v.enum_name, v.index)
            return
        }
        match e.kind {
            Int(n) {
                self.asm.mov_imm(RAX, n)
            }
            Float(x) {
                self.asm.mov_imm(RAX, float_bits(x))
            }
            Bool(b) {
                if b {
                    self.asm.mov_imm(RAX, 1)
                } else {
                    self.asm.mov_imm(RAX, 0)
                }
            }
            Str(parts) {
                var pieces: [Piece] = []
                for p in parts {
                    match p {
                        Lit(s) {
                            pieces.push(Piece.Text(s))
                        }
                        Code(inner) {
                            pieces.push(Piece.Code(inner))
                        }
                    }
                }
                self.concat(pieces)
            }
            Ident(name) {
                var found = self.lookup(name)
                if found.len() > 0 {
                    self.load_loc(RAX, found[0].loc)
                    if found[0].is_ref {
                        self.retain(RAX)
                    }
                } else if self.items.has(name) {
                    var closure = self.static_closure(name)
                    self.asm.lea(RAX, closure)
                } else {
                    self.unsupported(e.start, e.end, "this kind of name used as a value")
                }
            }
            List(items) {
                var td = self.descriptor(ty)
                self.asm.lea(RAX, td)
                self.asm.push(RAX)
                self.asm.push_imm(items.len())
                self.call_runtime("__rt_list_new", 2)
                if items.len() == 0 {
                    return
                }
                // The list has room for every item: they are stored directly.
                self.asm.push(RAX)
                for i in 0..items.len() {
                    self.expr(items[i])
                    self.asm.load(RCX, RSP, 0)
                    self.asm.load(RCX, RCX, LIST_DATA)
                    self.asm.store(RCX, 8 * i, RAX)
                }
                self.asm.pop(RAX)
                self.asm.store_imm(RAX, LIST_LEN, items.len())
            }
            StructLit(name, _, _, fields) {
                var order = self.an.structs[name].fields
                var td = self.descriptor(ty)
                self.asm.lea(RAX, td)
                self.asm.push(RAX)
                self.asm.push_imm(FIELDS + 8 * order.len())
                self.call_runtime("__rt_new", 2)
                if order.len() == 0 {
                    return
                }
                self.asm.push(RAX)
                for i in 0..order.len() {
                    var init: [ast.FieldInit] = []
                    for f in fields {
                        if init.len() == 0 && f.name == order[i].name {
                            init = [f]
                        }
                    }
                    if init.len() == 0 {
                        continue
                    }
                    var value = init[0].value
                    var offset = FIELDS + 8 * i
                    var operand = self.simple(value)
                    var done = false
                    if operand.len() > 0 {
                        match operand[0] {
                            Imm(v) {
                                self.asm.load(RCX, RSP, 0)
                                self.asm.store_imm(RCX, offset, v)
                                done = true
                            }
                            else {
                                var r = operand_reg(operand[0])
                                if r >= 0 {
                                    self.asm.load(RCX, RSP, 0)
                                    self.asm.store(RCX, offset, r)
                                    done = true
                                }
                            }
                        }
                    }
                    if !done {
                        self.expr(value)
                        self.asm.load(RCX, RSP, 0)
                        self.asm.store(RCX, offset, RAX)
                    }
                }
                self.asm.pop(RAX)
            }
            Unary(op, inner) {
                if op == ast.UnOp.Neg && ty == checker.Type.Float {
                    // Only the sign bit changes.
                    self.expr(inner)
                    self.asm.mov_imm(RCX, 0x8000000000000000)
                    self.asm.alu(ALU_XOR, RAX, RCX)
                } else {
                    self.expr(inner)
                    if op == ast.UnOp.Neg {
                        self.asm.neg(RAX)
                    } else {
                        self.asm.alu_imm(ALU_XOR, RAX, 1)
                    }
                }
            }
            Binary(op, lhs, rhs) {
                self.binary(e, op, lhs, rhs)
            }
            Call(callee, args) {
                self.call(e, callee, args)
            }
            Field(obj, name, _, _) {
                // An error is its message.
                if self.ty(obj) == checker.Type.Error {
                    self.expr(obj)
                    return
                }
                var offset = self.field_offset(obj, name)
                if offset.len() == 0 {
                    self.unsupported(e.start, e.end, "fields of this type")
                    return
                }
                if self.is_place(e) {
                    self.place(e)
                    if is_ref(ty) {
                        self.retain(RAX)
                    }
                } else {
                    // The object is a temporary value: read the field, then drop it.
                    var owned = self.operand(obj)
                    if owned {
                        self.asm.push(RAX)
                    }
                    self.asm.load(RAX, RAX, offset[0])
                    if is_ref(ty) {
                        self.retain(RAX)
                    }
                    if owned {
                        self.release_saved()
                    }
                }
            }
            Index(obj, index) {
                match self.ty(obj) {
                    Map(_, _) {
                        var key = self.key_arg(index)
                        self.call_rt("__rt_map_at", [Arg.Borrow(obj), key], true)
                        return
                    }
                    Str {
                        self.call_rt("__rt_str_index", [Arg.Borrow(obj), Arg.Value(index)], true)
                        return
                    }
                    else {
                    }
                }
                if self.is_place(e) {
                    self.place(e)
                    if is_ref(ty) {
                        self.retain(RAX)
                    }
                } else {
                    var owned = self.operand(obj)
                    self.asm.push(RAX)
                    self.expr(index)
                    self.asm.load(RCX, RSP, 0)
                    self.element_address()
                    self.asm.load_indexed(RAX, RCX, RAX)
                    if is_ref(ty) {
                        self.retain(RAX)
                    }
                    if owned {
                        self.release_saved()
                    } else {
                        self.asm.alu_imm(ALU_ADD, RSP, 8)
                    }
                }
            }
            Try(call) {
                // On failure the error goes straight to this function's caller.
                // The lowering pass made sure nothing else is pending here.
                self.expr(call)
                var fine = self.asm.new_label()
                self.asm.test(RDX, RDX)
                self.asm.jcc(CC_E, fine)
                self.leave_with_error(RDX, [])
                self.asm.bind(fine)
            }
            Or(call, default) {
                // When either side waits, the JavaScript target goes through
                // a helper that waits a few more turns; so do we.
                var waits = self.an.has_forks && (self.awaits(call) || self.awaits(default))
                self.expr(call)
                var fine = self.asm.new_label()
                var end = self.asm.new_label()
                self.asm.test(RDX, RDX)
                self.asm.jcc(CC_E, fine)
                self.asm.mov(RAX, RDX)
                self.release_rax()
                if waits {
                    self.yield_point()
                }
                self.expr(default)
                if waits {
                    for _ in 0..3 {
                        self.yield_point()
                    }
                }
                self.asm.jmp(end)
                self.asm.bind(fine)
                if waits {
                    self.yield_point()
                    self.yield_point()
                }
                self.asm.bind(end)
            }
            Catch(_, _, _, _, _) {
                self.unsupported(e.start, e.end, "this use of `catch`")
            }
            Range(_, _) {
                self.unsupported(e.start, e.end, "ranges outside of a `for` loop")
            }
            Map(entries) {
                var td = self.descriptor(ty)
                self.asm.lea(RAX, td)
                self.asm.push(RAX)
                self.call_runtime("__rt_map_new", 1)
                if entries.len() == 0 {
                    return
                }
                self.asm.push(RAX)
                for entry in entries {
                    self.asm.load(RAX, RSP, 0)
                    self.asm.push(RAX)
                    var key_owned = self.push_arg(entry.key)
                    self.expr(entry.value)
                    self.asm.push(RAX)
                    self.call_runtime("__rt_map_set", 0)
                    self.drop_args([false, key_owned, false], false)
                }
                self.asm.pop(RAX)
            }
            Lambda(_, _, _, _) {
                var key = checker.lambda_key(e.id)
                var captures: [checker.Captured] = []
                if self.an.captures.has(e.id) {
                    captures = self.an.captures[e.id]
                }
                if captures.len() == 0 {
                    var closure = self.static_closure(key)
                    self.asm.lea(RAX, closure)
                    return
                }
                // The closure: the address of the code, then what it captures.
                var types: [checker.Type] = []
                for c in captures {
                    types.push(c.ty)
                }
                for t in types {
                    self.check_type(t, e.start, e.end)
                }
                var td = self.closure_descriptor(types)
                self.asm.lea(RAX, td)
                self.asm.push(RAX)
                self.asm.push_imm(FIELDS + 8 * (1 + captures.len()))
                self.call_runtime("__rt_new", 2)
                var code = self.function_label(key)
                self.asm.lea(RCX, code)
                self.asm.store(RAX, FIELDS, RCX)
                for i in 0..captures.len() {
                    var c = captures[i]
                    var found = self.lookup(c.name)
                    if found.len() == 0 {
                        continue
                    }
                    self.load_loc(RCX, found[0].loc)
                    if is_ref(c.ty) {
                        self.retain(RCX)
                    }
                    self.asm.store(RAX, FIELDS + 8 + 8 * i, RCX)
                }
            }
            Recv(channel) {
                var owned = [self.push_arg(channel)]
                self.call_runtime("__rt_chan_recv", 0)
                self.drop_args(owned, true)
            }
            ChanNew(_, cap) {
                var td = self.descriptor(ty)
                self.asm.lea(RAX, td)
                self.asm.push(RAX)
                if cap.len() > 0 {
                    self.push_value(cap[0])
                } else {
                    self.asm.push_imm(0)
                }
                self.call_runtime("__rt_chan_new", 2)
            }
        }
    }

    fn binary(self, e: ast.Expr, op: ast.BinOp, lhs: ast.Expr, rhs: ast.Expr) {
        // Comparing a struct with an interface: let the objects tell their type.
        var l = self.ty(lhs)
        var r = self.ty(rhs)
        var operand_ty = l
        match r {
            Interface(_) {
                operand_ty = r
            }
            else {
            }
        }
        if op == ast.BinOp.And || op == ast.BinOp.Or {
            // Short-circuit: the right side only runs when it can change the result.
            var end = self.asm.new_label()
            self.expr(lhs)
            self.asm.test(RAX, RAX)
            if op == ast.BinOp.And {
                self.asm.jcc(CC_E, end)
            } else {
                self.asm.jcc(CC_NE, end)
            }
            self.expr(rhs)
            self.asm.bind(end)
            return
        }
        if operand_ty == checker.Type.Str {
            self.string_binary(op, lhs, rhs)
            return
        }
        if is_arith(op) && operand_ty == checker.Type.Float {
            self.float(e)
            self.asm.movq_out(RAX, XMM0)
            return
        }
        if operand_ty == checker.Type.Float {
            var cc = self.float_compare(op, lhs, rhs)
            if cc == CC_E || cc == CC_NE {
                // Equal only if both are numbers, too.
                var unordered = self.asm.jcc_short(CC_P)
                self.asm.setcc(cc)
                var done = self.asm.jmp_short()
                self.asm.bind_short(unordered)
                if cc == CC_NE {
                    self.asm.mov_imm(RAX, 1)
                } else {
                    self.asm.mov_imm(RAX, 0)
                }
                self.asm.bind_short(done)
            } else {
                self.asm.setcc(cc)
            }
            return
        }
        if is_ref(operand_ty) {
            // Lists and structs are compared by content.
            self.call_rt("__rt_eq", [Arg.Borrow(lhs), Arg.Borrow(rhs), Arg.Descriptor(operand_ty)], true)
            if op == ast.BinOp.NotEq {
                self.asm.alu_imm(ALU_XOR, RAX, 1)
            }
            return
        }
        if is_arith(op) {
            self.arith(op, lhs, rhs)
            return
        }
        var cc = self.compare(op, lhs, rhs)
        self.asm.setcc(cc)
    }

    // Evaluates `e` to use it right away. A local variable or a constant is
    // read without counting a new reference; the result says whether the
    // caller received a reference it has to release.
    fn operand(self, e: ast.Expr) -> bool {
        for v in self.local(e) {
            self.load_loc(RAX, v.loc)
            return false
        }
        match e.kind {
            Str(parts) {
                for text in plain(parts) {
                    var label = self.string(text)
                    self.asm.lea(RAX, label)
                    return false
                }
            }
            else {
            }
        }
        self.expr(e)
        return is_ref(self.ty(e))
    }

    // Like `operand`, but also borrows from top-level variables, fields and
    // list elements. Only valid when the value is consumed before any code
    // of the program can run again (which could replace what was borrowed).
    fn operand_now(self, e: ast.Expr) -> bool {
        if self.is_place(e) {
            self.place(e)
            return false
        }
        return self.operand(e)
    }

    // Is `e` a variable, or a field or element reached from one without calling anything?
    fn is_place(self, e: ast.Expr) -> bool {
        match e.kind {
            Ident(name) {
                return self.lookup(name).len() > 0
            }
            Field(obj, _, _, _) {
                return is_struct(self.ty(obj)) && self.is_place(obj)
            }
            Index(obj, index) {
                return is_list(self.ty(obj)) && self.is_place(obj) && self.is_pure(index)
            }
            else {
                return false
            }
        }
    }

    // Loads the value of a place into RAX, without counting a reference.
    fn place(self, e: ast.Expr) {
        match e.kind {
            Ident(name) {
                for v in self.lookup(name) {
                    self.load_loc(RAX, v.loc)
                }
            }
            Field(obj, name, _, _) {
                var offset = 0
                for o in self.field_offset(obj, name) {
                    offset = o
                }
                var r = -1
                for v in self.local(obj) {
                    match v.loc {
                        Reg(reg) {
                            r = reg
                        }
                        else {
                        }
                    }
                }
                if r >= 0 {
                    self.asm.load(RAX, r, offset)
                } else {
                    self.place(obj)
                    self.asm.load(RAX, RAX, offset)
                }
            }
            Index(obj, index) {
                var position = self.simple(index)
                if position.len() > 0 {
                    self.place(obj)
                    self.asm.mov(RCX, RAX)
                    self.load_operand(RAX, position[0])
                } else {
                    self.place(obj)
                    self.asm.push(RAX)
                    self.expr(index)
                    self.asm.pop(RCX)
                }
                self.element_address()
                self.asm.load_indexed(RAX, RCX, RAX)
            }
            else {
                self.expr(e)
            }
        }
    }

    // Evaluating `e` runs no code of the program: only reads, arithmetic and
    // runtime helpers. Nothing a pure expression does can release an object.
    fn is_pure(self, e: ast.Expr) -> bool {
        match e.kind {
            Int(_), Float(_), Bool(_) {
                return true
            }
            Str(parts) {
                for p in parts {
                    match p {
                        Code(inner) {
                            if !self.is_pure(inner) {
                                return false
                            }
                        }
                        else {
                        }
                    }
                }
                return true
            }
            Ident(name) {
                return self.lookup(name).len() > 0
            }
            Unary(_, inner) {
                return self.is_pure(inner)
            }
            Binary(_, lhs, rhs) {
                return self.is_pure(lhs) && self.is_pure(rhs)
            }
            Field(obj, _, _, _) {
                return is_struct(self.ty(obj)) && self.is_pure(obj)
            }
            Index(obj, index) {
                var ty = self.ty(obj)
                return (is_list(ty) || ty == checker.Type.Str) && self.is_pure(obj) && self.is_pure(index)
            }
            Call(callee, args) {
                var receiver_pure = true
                match callee.kind {
                    Field(obj, _, _, _) {
                        receiver_pure = self.is_pure(obj)
                    }
                    else {
                    }
                }
                var harmless = false
                if self.an.calls.has(e.id) {
                    match self.an.calls[e.id] {
                        Builtin(name) {
                            harmless = harmless_builtins().contains(name)
                        }
                        BuiltinMethod(recv, name) {
                            // Strings never change: all their methods only read them.
                            harmless = recv == checker.Recv.Str || name == "len" || name == "contains" || name == "index_of"
                        }
                        else {
                        }
                    }
                }
                if !harmless || !receiver_pure {
                    return false
                }
                for a in args {
                    if !self.is_pure(a) {
                        return false
                    }
                }
                return true
            }
            else {
                return false
            }
        }
    }

    fn field_offset(self, obj: ast.Expr, field: string) -> [int] {
        match self.ty(obj) {
            Struct(name) {
                var fields = self.an.structs[name].fields
                for i in 0..fields.len() {
                    if fields[i].name == field {
                        return [FIELDS + 8 * i]
                    }
                }
                return []
            }
            else {
                return []
            }
        }
    }

    // With a list in RCX and a position in RAX: checks the position, then
    // leaves the address of the list's elements in RCX (the element is at
    // `[RCX + RAX * 8]`).
    fn element_address(self) {
        // Unsigned comparison: a negative position looks huge.
        self.asm.alu_load(ALU_CMP, RAX, RCX, LIST_LEN)
        var out_of_bounds = self.index_oob_label()
        self.asm.jcc(CC_AE, out_of_bounds)
        self.asm.load(RCX, RCX, LIST_DATA)
    }

    // ---- expressions: strings ----

    // Evaluates `e` and converts it to a string in RAX. Returns whether the
    // caller owns that string.
    fn to_str(self, e: ast.Expr) -> bool {
        var ty = self.ty(e)
        match ty {
            Str, Error {
                self.expr(e)
                return true
            }
            Int {
                self.push_value(e)
                self.call_runtime("__rt_int_str", 1)
                return true
            }
            Float {
                self.push_value(e)
                self.call_runtime("__rt_float_str", 1)
                return true
            }
            Bool {
                var yes = self.string("true")
                var no = self.string("false")
                self.expr(e)
                self.asm.test(RAX, RAX)
                self.asm.lea(RAX, no)
                var done = self.asm.jcc_short(CC_E)
                self.asm.lea(RAX, yes)
                self.asm.bind_short(done)
                return false
            }
            else {
                self.call_rt("__rt_repr", [Arg.Borrow(e), Arg.Descriptor(ty), Arg.Const(0)], true)
                return true
            }
        }
    }

    // Pushes the pieces of a string, each as a string. Returns which ones
    // have to be released afterwards, and how many bytes of the stack, above
    // the pieces, hold the text of numbers.
    fn push_pieces(self, pieces: [Piece]) -> Pushed {
        // When no piece runs code of the program, strings can be borrowed
        // from wherever they are stored.
        var pure = true
        var numbers = 0
        for p in pieces {
            match p {
                Code(e) {
                    if !self.is_pure(e) {
                        pure = false
                    }
                    if self.ty(e) == checker.Type.Int {
                        numbers += 1
                    }
                }
                else {
                }
            }
        }
        // A number becomes text in a small buffer on the stack, reserved
        // here: showing it allocates nothing.
        if numbers > 0 {
            self.asm.alu_imm(ALU_SUB, RSP, NUMBER_BUFFER * numbers)
        }
        var used = 0
        var owned: [bool] = []
        for pushed in 0..pieces.len() {
            var o = false
            match pieces[pushed] {
                Text(text) {
                    var label = self.string(text)
                    self.asm.lea(RAX, label)
                }
                Code(e) {
                    var ty = self.ty(e)
                    if ty == checker.Type.Str || ty == checker.Type.Error {
                        if pure {
                            o = self.operand_now(e)
                        } else {
                            o = self.operand(e)
                        }
                    } else if ty == checker.Type.Int {
                        self.expr(e)
                        self.asm.lea_mem(RCX, RSP, 8 * pushed + NUMBER_BUFFER * used)
                        self.asm.push(RCX)
                        self.asm.push(RAX)
                        self.call_runtime("__rt_int_into", 2)
                        used += 1
                    } else {
                        o = self.to_str(e)
                    }
                }
            }
            owned.push(o)
            self.asm.push(RAX)
        }
        return Pushed{owned: owned, extra: NUMBER_BUFFER * numbers}
    }

    // Removes what `push_pieces` left on the stack, releasing the temporary strings.
    fn drop_pieces(self, pushed: Pushed, keep_result: bool) {
        self.drop_args(pushed.owned, keep_result)
        if pushed.extra > 0 {
            self.asm.alu_imm(ALU_ADD, RSP, pushed.extra)
        }
    }

    // Builds one string out of pieces; leaves it, owned, in RAX.
    fn concat(self, pieces: [Piece]) {
        if pieces.len() == 0 {
            var empty = self.string("")
            self.asm.lea(RAX, empty)
            return
        }
        if pieces.len() == 1 {
            match pieces[0] {
                Text(text) {
                    var label = self.string(text)
                    self.asm.lea(RAX, label)
                }
                Code(e) {
                    self.to_str(e)
                }
            }
            return
        }
        if pieces.len() == 2 {
            match pieces[0] {
                Code(a) {
                    match pieces[1] {
                        Code(b) {
                            if self.ty(a) == checker.Type.Str && self.ty(b) == checker.Type.Str {
                                self.call_rt("__rt_concat", [Arg.Borrow(a), Arg.Borrow(b)], true)
                                return
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
        // One allocation for the whole string, whatever the number of pieces.
        var pushed = self.push_pieces(pieces)
        self.asm.mov(RAX, RSP)
        self.asm.push(RAX)
        self.asm.push_imm(pieces.len())
        self.call_runtime("__rt_concat_n", 2)
        self.drop_pieces(pushed, true)
    }

    // An operation on two strings; the result goes to RAX.
    fn string_binary(self, op: ast.BinOp, lhs: ast.Expr, rhs: ast.Expr) {
        if op == ast.BinOp.Add {
            // `a + b + c` is assembled in one go.
            var pieces: [Piece] = []
            add_leaves(lhs, pieces)
            add_leaves(rhs, pieces)
            self.concat(pieces)
            return
        }
        if op == ast.BinOp.Eq || op == ast.BinOp.NotEq {
            self.call_rt("__rt_str_eq", [Arg.Borrow(lhs), Arg.Borrow(rhs)], true)
            if op == ast.BinOp.NotEq {
                self.asm.alu_imm(ALU_XOR, RAX, 1)
            }
            return
        }
        // Ordering: compare the result of str_cmp with zero.
        self.call_rt("__rt_str_cmp", [Arg.Borrow(lhs), Arg.Borrow(rhs)], true)
        self.asm.alu_imm(ALU_CMP, RAX, 0)
        self.asm.setcc(cc_of(op))
    }

    // ---- expressions: arithmetic ----

    // `lhs op rhs` on integers; the result goes to RAX.
    fn arith(self, op: ast.BinOp, lhs: ast.Expr, rhs: ast.Expr) {
        var right = self.simple(rhs)
        if right.len() > 0 {
            self.expr(lhs)
            match right[0] {
                Imm(v) {
                    self.arith_imm(op, v)
                }
                else {
                    self.arith_operand(op, right[0])
                }
            }
            return
        }
        var left = self.simple(lhs)
        if left.len() > 0 && !is_global_operand(left[0]) {
            // The left side is a constant or a local variable: computing
            // the right side first cannot change it.
            self.expr(rhs)
            if op == ast.BinOp.Add || op == ast.BinOp.Mul {
                match left[0] {
                    Imm(v) {
                        self.arith_imm(op, v)
                    }
                    else {
                        self.arith_operand(op, left[0])
                    }
                }
            } else {
                self.asm.mov(RCX, RAX)
                self.load_operand(RAX, left[0])
                self.arith_rcx(op)
            }
            return
        }
        self.expr(lhs)
        self.asm.push(RAX)
        self.expr(rhs)
        self.asm.mov(RCX, RAX)
        self.asm.pop(RAX)
        self.arith_rcx(op)
    }

    // `RAX = RAX op RCX`
    fn arith_rcx(self, op: ast.BinOp) {
        match op {
            Add {
                self.asm.alu(ALU_ADD, RAX, RCX)
            }
            Sub {
                self.asm.alu(ALU_SUB, RAX, RCX)
            }
            Mul {
                self.asm.imul(RAX, RCX)
            }
            else {
                self.divide(op == ast.BinOp.Mod)
            }
        }
    }

    // `RAX = RAX op variable`
    fn arith_operand(self, op: ast.BinOp, operand: Operand) {
        if op == ast.BinOp.Add {
            self.operand_alu(ALU_ADD, RAX, operand)
            return
        }
        if op == ast.BinOp.Sub {
            self.operand_alu(ALU_SUB, RAX, operand)
            return
        }
        if op == ast.BinOp.Mul {
            match operand {
                At(loc) {
                    match loc {
                        Reg(r) {
                            self.asm.imul(RAX, r)
                        }
                        Frame(offset) {
                            self.asm.imul_load(RAX, RBP, offset)
                        }
                        Global(offset) {
                            self.asm.imul_load(RAX, R15, offset)
                        }
                    }
                    return
                }
                else {
                }
            }
        }
        self.load_operand(RCX, operand)
        self.divide(op == ast.BinOp.Mod)
    }

    // `RAX = RAX op constant`
    fn arith_imm(self, op: ast.BinOp, v: int) {
        match op {
            Add {
                if v != 0 {
                    self.asm.alu_imm(ALU_ADD, RAX, as_i32(v))
                }
            }
            Sub {
                if v != 0 {
                    self.asm.alu_imm(ALU_SUB, RAX, as_i32(v))
                }
            }
            Mul {
                if v == 0 {
                    self.asm.mov_imm(RAX, 0)
                } else if v == 1 {
                } else if v == -1 {
                    self.asm.neg(RAX)
                } else if v > 0 && is_power_of_two(v) {
                    self.asm.shift(SHIFT_LEFT, RAX, trailing_zeros(v))
                } else {
                    self.asm.imul_imm(RAX, RAX, as_i32(v))
                }
            }
            else {
                self.divide_by(v, op == ast.BinOp.Mod)
            }
        }
    }

    // RAX / RCX (or RAX % RCX), with a panic on division by zero.
    fn divide(self, remainder: bool) {
        self.asm.test(RCX, RCX)
        var zero = self.div_zero_label()
        self.asm.jcc(CC_E, zero)
        // The processor traps on MIN / -1, so dividing by -1 is done by hand.
        self.asm.alu_imm(ALU_CMP, RCX, -1)
        var normal = self.asm.jcc_short(CC_NE)
        if remainder {
            self.asm.mov_imm(RAX, 0)
        } else {
            self.asm.neg(RAX)
        }
        var done = self.asm.jmp_short()
        self.asm.bind_short(normal)
        self.asm.cqo()
        self.asm.idiv(RCX)
        if remainder {
            self.asm.mov(RAX, RDX)
        }
        self.asm.bind_short(done)
    }

    // RAX / d (or RAX % d) for a constant `d`, without a division instruction.
    fn divide_by(self, d: int, remainder: bool) {
        if d == 0 {
            var zero = self.div_zero_label()
            self.asm.jmp(zero)
            return
        }
        // As an unsigned number: the absolute value of the minimum is 2^63.
        var magnitude = abs(d)
        if magnitude == 1 {
            if remainder {
                self.asm.mov_imm(RAX, 0)
            } else if d < 0 {
                self.asm.neg(RAX)
            }
            return
        }
        if is_power_of_two(magnitude) {
            // Rounding goes towards zero: negative numbers get (2^k - 1) added first.
            var k = trailing_zeros(magnitude)
            self.asm.mov(RCX, RAX)
            self.asm.shift(SHIFT_RIGHT_SIGNED, RCX, 63)
            self.asm.shift(SHIFT_RIGHT, RCX, 64 - k)
            self.asm.alu(ALU_ADD, RAX, RCX)
            if remainder {
                self.asm.alu_imm(ALU_AND, RAX, as_i32(magnitude - 1))
                self.asm.alu(ALU_SUB, RAX, RCX)
            } else {
                self.asm.shift(SHIFT_RIGHT_SIGNED, RAX, k)
                if d < 0 {
                    self.asm.neg(RAX)
                }
            }
            return
        }
        // The remainder has the sign of the dividend, whatever the divisor's.
        var divisor = d
        if remainder {
            divisor = magnitude
        }
        var found = magic_number(divisor)
        var magic = found[0]
        var shift = found[1]
        self.asm.mov(RCX, RAX)
        self.asm.mov_imm(RAX, magic)
        self.asm.imul_wide(RCX)
        if divisor > 0 && magic < 0 {
            self.asm.alu(ALU_ADD, RDX, RCX)
        }
        if divisor < 0 && magic > 0 {
            self.asm.alu(ALU_SUB, RDX, RCX)
        }
        if shift > 0 {
            self.asm.shift(SHIFT_RIGHT_SIGNED, RDX, shift)
        }
        self.asm.mov(RAX, RDX)
        self.asm.shift(SHIFT_RIGHT, RAX, 63)
        self.asm.alu(ALU_ADD, RAX, RDX)
        if remainder {
            self.asm.imul_imm(RAX, RAX, as_i32(magnitude))
            self.asm.alu(ALU_SUB, RCX, RAX)
            self.asm.mov(RAX, RCX)
        }
    }

    // ---- expressions: calls ----

    // Pushes an argument. A reference held by a local variable is lent as
    // is; anything else is a temporary value, to release after the call.
    fn push_arg(self, e: ast.Expr) -> bool {
        if is_ref(self.ty(e)) {
            var owned = self.operand(e)
            self.asm.push(RAX)
            return owned
        }
        self.push_value(e)
        return false
    }

    // Like `call_rt`, for a runtime function that can fail.
    fn call_rt_fallible(self, name: string, args: [Arg], has_result: bool) {
        self.rt_fallible = true
        self.call_rt(name, args, has_result)
    }

    // Calls a runtime function. The runtime never runs code of the program,
    // so when the arguments do not either, references can be borrowed from
    // wherever they are stored.
    fn call_rt(self, name: string, args: [Arg], has_result: bool) {
        var fallible = self.rt_fallible
        self.rt_fallible = false
        var pure = true
        for arg in args {
            match arg {
                Borrow(e) {
                    if !self.is_pure(e) {
                        pure = false
                    }
                }
                Move(e) {
                    if !self.is_pure(e) {
                        pure = false
                    }
                }
                Value(e) {
                    if !self.is_pure(e) {
                        pure = false
                    }
                }
                else {
                }
            }
        }
        var owned: [bool] = []
        for arg in args {
            var o = false
            match arg {
                Borrow(e) {
                    if pure {
                        o = self.operand_now(e)
                    } else {
                        o = self.operand(e)
                    }
                    self.asm.push(RAX)
                }
                Move(e) {
                    self.expr(e)
                    self.asm.push(RAX)
                }
                Value(e) {
                    self.push_value(e)
                }
                Const(v) {
                    self.asm.push_imm(as_i32(v))
                }
                Descriptor(ty) {
                    var td = self.descriptor(ty)
                    self.asm.lea(RAX, td)
                    self.asm.push(RAX)
                }
            }
            owned.push(o)
        }
        self.call_runtime(name, 0)
        self.keep_error = fallible
        self.drop_args(owned, has_result)
    }

    fn call(self, e: ast.Expr, callee: ast.Expr, args: [ast.Expr]) {
        var has_result = self.ty(e) != checker.Type.Void
        var fallible = self.an.fallible_calls.has(e.id)
        if !self.an.calls.has(e.id) {
            self.unsupported(e.start, e.end, "calls through function values")
            return
        }
        // The object a method is called on, when the callee is `obj.name`.
        var receiver: [ast.Expr] = []
        var field_name = ""
        match callee.kind {
            Field(obj, name, _, _) {
                receiver = [obj]
                field_name = name
            }
            else {
            }
        }
        match self.an.calls[e.id] {
            Fn(name) {
                var owned: [bool] = []
                for a in args {
                    owned.push(self.push_arg(a))
                }
                var label = self.function_label(name)
                self.asm.call(label)
                self.reload_floats()
                self.keep_error = fallible
                self.drop_args(owned, has_result)
                if self.an.async_keys.has(checker.fn_key(name)) {
                    self.yield_point()
                }
            }
            Method(strukt, name) {
                // `self` is the first argument.
                if receiver.len() == 0 {
                    return
                }
                var owned = [self.push_arg(receiver[0])]
                for a in args {
                    owned.push(self.push_arg(a))
                }
                var label = self.function_label(checker.method_key(strukt, name))
                self.asm.call(label)
                self.reload_floats()
                self.keep_error = fallible
                self.drop_args(owned, has_result)
                if self.an.async_keys.has(checker.method_key(strukt, name)) {
                    self.yield_point()
                }
            }
            Dynamic {
                var through_interface = false
                for obj in receiver {
                    match self.ty(obj) {
                        Interface(_) {
                            through_interface = true
                        }
                        else {
                        }
                    }
                }
                if !through_interface {
                    // A call through a function value: the closure waits under
                    // the arguments, and travels to its code in R10.
                    var owned = [self.push_arg(callee)]
                    for a in args {
                        owned.push(self.push_arg(a))
                    }
                    self.asm.load(R10, RSP, 8 * args.len())
                    self.asm.call_mem(R10, FIELDS)
                    self.reload_floats()
                    self.keep_error = fallible
                    self.drop_args(owned, has_result)
                    self.yield_point()
                } else {
                    var owned = [self.push_arg(receiver[0])]
                    for a in args {
                        owned.push(self.push_arg(a))
                    }
                    self.interface_call(field_name, args.len())
                    self.keep_error = fallible
                    self.drop_args(owned, has_result)
                    self.yield_point()
                }
            }
            Builtin(name) {
                self.builtin(name, e, args)
            }
            BuiltinMethod(recv, name) {
                if receiver.len() == 0 {
                    return
                }
                var obj = receiver[0]
                match recv {
                    Str {
                        self.string_method(e, obj, name, args)
                    }
                    List {
                        self.list_method(e, obj, name, args)
                    }
                    Map {
                        self.map_method(e, obj, name, args)
                    }
                    Weak {
                        if name == "get" {
                            self.call_rt_fallible("__rt_weak_get", [Arg.Borrow(obj)], true)
                        } else {
                            self.unsupported(e.start, e.end, "calls to the method `" + name + "`")
                        }
                    }
                    Chan {
                        if name == "close" {
                            var owned = [self.push_arg(obj)]
                            self.call_runtime("__rt_chan_close", 0)
                            self.drop_args(owned, false)
                        } else {
                            self.unsupported(e.start, e.end, "calls to the method `" + name + "`")
                        }
                    }
                }
            }
        }
    }

    // Calls the method `name` of the object pushed `args + 1` slots ago,
    // whose struct is only known when the program runs. Each call site
    // remembers the last type it saw and the method it found for it, so the
    // search only happens when the type changes.
    fn interface_call(self, name: string, args: int) {
        var cache = STATE_SIZE + 8 * self.globals.len() + 16 * self.caches
        self.caches += 1
        self.asm.load(RAX, RSP, 8 * args)
        self.asm.load32(RCX, RAX, DESCRIPTOR)
        self.asm.alu_load(ALU_CMP, RCX, R15, cache)
        var miss = self.asm.jcc_short(CC_NE)
        self.asm.call_mem(R15, cache + 8)
        self.reload_floats()
        var done = self.asm.jmp_short()
        self.asm.bind_short(miss)
        self.asm.store(R15, cache, RCX)
        self.asm.push(RAX)
        var name_label = self.string(name)
        self.asm.lea(RAX, name_label)
        self.asm.push(RAX)
        self.call_runtime("__rt_find_method", 2)
        self.asm.store(R15, cache + 8, RAX)
        self.asm.call_reg(RAX)
        self.reload_floats()
        self.asm.bind_short(done)
    }

    // A map key as an argument for the runtime: strings are lent, the rest is a plain value.
    fn key_arg(self, key: ast.Expr) -> Arg {
        if is_ref(self.ty(key)) {
            return Arg.Borrow(key)
        }
        return Arg.Value(key)
    }

    fn map_method(self, e: ast.Expr, obj: ast.Expr, name: string, args: [ast.Expr]) {
        match self.ty(obj) {
            Map(key_ty, value_ty) {
                if name == "len" {
                    var owned = self.operand(obj)
                    if owned {
                        self.asm.push(RAX)
                    }
                    self.asm.load(RAX, RAX, 8)
                    if owned {
                        self.release_saved()
                    }
                } else if name == "get" {
                    var key = self.key_arg(args[0])
                    self.call_rt_fallible("__rt_map_get", [Arg.Borrow(obj), key], true)
                } else if name == "has" {
                    var key = self.key_arg(args[0])
                    self.call_rt("__rt_map_has", [Arg.Borrow(obj), key], true)
                } else if name == "remove" {
                    var key = self.key_arg(args[0])
                    self.call_rt("__rt_map_remove", [Arg.Borrow(obj), key], false)
                } else if name == "clear" {
                    self.call_rt("__rt_map_clear", [Arg.Borrow(obj)], false)
                } else if name == "keys" {
                    var list = Arg.Descriptor(checker.Type.List(key_ty))
                    self.call_rt("__rt_map_list", [Arg.Borrow(obj), list, Arg.Const(8)], true)
                } else if name == "values" {
                    var list = Arg.Descriptor(checker.Type.List(value_ty))
                    self.call_rt("__rt_map_list", [Arg.Borrow(obj), list, Arg.Const(16)], true)
                } else {
                    self.unsupported(e.start, e.end, "calls to the map method `" + name + "`")
                }
            }
            else {
            }
        }
    }

    // `map[key] = value` and `map[key] op= value`.
    fn assign_entry(self, obj: ast.Expr, key: ast.Expr, ty: checker.Type, bin: [ast.BinOp], value: ast.Expr) {
        if bin.len() == 0 {
            var key_arg = self.key_arg(key)
            var value_arg = Arg.Value(value)
            if is_ref(ty) {
                value_arg = Arg.Move(value)
            }
            self.call_rt("__rt_map_set", [Arg.Borrow(obj), key_arg, value_arg], false)
            return
        }
        // The map and the key wait on the stack while the new value is computed.
        var map_owned = self.operand(obj)
        self.asm.push(RAX)
        var key_owned = self.push_arg(key)
        self.asm.load(RAX, RSP, 8)
        self.asm.push(RAX)
        self.asm.load(RAX, RSP, 8)
        self.asm.push(RAX)
        self.call_runtime("__rt_map_at", 2)
        if ty == checker.Type.Str {
            self.asm.push(RAX)
            var piece_owned = self.operand(value)
            self.asm.push(RAX)
            self.call_runtime("__rt_concat", 0)
            self.drop_args([true, piece_owned], true)
        } else {
            self.asm.push(RAX)
            self.expr(value)
            self.asm.mov(RCX, RAX)
            self.asm.pop(RAX)
            self.arith_rcx(bin[0])
        }
        self.asm.push(RAX)
        self.call_runtime("__rt_map_set", 1)
        self.drop_args([map_owned, key_owned], false)
    }

    // `for key in map`: the keys, in the order they were added.
    fn for_map(self, name: string, at: int, iter: ast.Expr, body: ast.Block, key: checker.Type) {
        var top = self.asm.new_label()
        var next = self.asm.new_label()
        var end = self.asm.new_label()
        // Outer scope: the map (kept alive for the whole loop) and the entry number.
        var outer: [Var] = []
        self.scopes.push(outer)
        self.expr(iter)
        var the_map = self.declare("<map>", plan.var_key(at, plan.SUBJECT), self.ty(iter))
        self.store_loc(the_map, RAX)
        var position = self.home(plan.var_key(at, plan.COUNTER))
        self.asm.mov_imm(RAX, 0)
        self.store_loc(position, RAX)

        self.asm.bind(top)
        // Removed entries are skipped; the search starts where the last turn stopped.
        self.load_loc(RAX, the_map)
        self.asm.push(RAX)
        self.load_loc(RAX, position)
        self.asm.push(RAX)
        self.call_runtime("__rt_map_next", 2)
        self.asm.alu_imm(ALU_CMP, RAX, 0)
        self.asm.jcc(CC_L, end)
        self.store_loc(position, RAX)
        self.load_loc(RCX, the_map)
        self.asm.push(RCX)
        self.asm.push(RAX)
        self.asm.push_imm(8)
        self.call_runtime("__rt_map_part", 3)

        // Inner scope: the loop variable, released after each turn.
        var inner: [Var] = []
        self.scopes.push(inner)
        if is_ref(key) {
            self.retain(RAX)
        }
        var item = self.declare(name, plan.var_key(at, plan.NAMED), key)
        self.store_loc(item, RAX)
        var depth = self.scopes.len()
        self.loops.push(Loop{next: next, end: end, continue_from: depth, break_from: depth - 1})
        self.block(body)
        self.loops.remove(self.loops.len() - 1)

        self.asm.bind(next)
        self.release_scopes(depth - 1)
        self.scopes.remove(self.scopes.len() - 1)
        self.load_loc(RAX, position)
        self.asm.alu_imm(ALU_ADD, RAX, 1)
        self.store_loc(position, RAX)
        self.asm.jmp(top)

        self.asm.bind(end)
        self.release_scopes(self.scopes.len() - 1)
        self.scopes.remove(self.scopes.len() - 1)
    }

    // ---- floats ----
    //
    // A float is stored like everything else, in 8 bytes: variables, fields,
    // list elements and RAX hold its bits. Computing happens in XMM0 and
    // XMM1; a whole expression such as `a * b + c * d` stays there, and only
    // its result goes back to RAX.

    // Loads the float stored at `loc`.
    fn float_load(self, dst: int, loc: Loc) {
        match loc {
            Reg(r) {
                self.asm.movq_in(dst, r)
            }
            Frame(offset) {
                if self.in_xmm.has(offset) {
                    self.asm.sse(SSE_MOV, dst, self.in_xmm[offset])
                } else {
                    self.asm.sse_load(SSE_MOV, dst, RBP, offset)
                }
            }
            Global(offset) {
                self.asm.sse_load(SSE_MOV, dst, R15, offset)
            }
        }
    }

    // Evaluates the float `e` into XMM0.
    fn float(self, e: ast.Expr) {
        match e.kind {
            Float(x) {
                self.asm.mov_imm(RAX, float_bits(x))
                self.asm.movq_in(XMM0, RAX)
                return
            }
            Binary(op, lhs, rhs) {
                if op == ast.BinOp.Mod && self.ty(e) == checker.Type.Float {
                    // The remainder comes from the processor's older floating-point
                    // unit, whose `fprem` is exact; it works on memory operands.
                    self.float(lhs)
                    self.asm.movq_out(RAX, XMM0)
                    self.asm.push(RAX)
                    self.float(rhs)
                    self.asm.movq_out(RAX, XMM0)
                    self.asm.push(RAX)
                    self.asm.bytes([0xDD, 0x04, 0x24])          // fld qword [rsp]      the divisor
                    self.asm.bytes([0xDD, 0x44, 0x24, 0x08])    // fld qword [rsp+8]  the dividend
                    self.asm.bytes([0xD9, 0xF8])                // fprem: a partial remainder...
                    self.asm.bytes([0xDF, 0xE0])                // fnstsw ax
                    self.asm.bytes([0xF6, 0xC4, 0x04])          // test ah, 4
                    self.asm.bytes([0x75, 0xF7])                // jnz fprem: ...until it is complete
                    self.asm.bytes([0xDD, 0x5C, 0x24, 0x08])    // fstp qword [rsp+8]
                    self.asm.bytes([0xDD, 0xD8])                // fstp st(0)
                    self.asm.pop(RAX)
                    self.asm.pop(RAX)
                    self.asm.movq_in(XMM0, RAX)
                    return
                }
                if is_float_op(op) && self.ty(e) == checker.Type.Float {
                    self.float_binary(sse_of(op), lhs, rhs)
                    return
                }
            }
            Call(_, args) {
                var name = self.builtin_name(e)
                if name == "float" && self.ty(args[0]) == checker.Type.Int {
                    self.expr(args[0])
                    // Clearing the register first tells the processor that
                    // its old content does not matter.
                    self.asm.pxor(XMM0, XMM0)
                    self.asm.cvtsi2sd(XMM0, RAX)
                } else if name == "float" {
                    self.float(args[0])
                } else if name == "sqrt" {
                    self.float(args[0])
                    self.asm.sse(SSE_SQRT, XMM0, XMM0)
                } else {
                    self.expr(e)
                    self.asm.movq_in(XMM0, RAX)
                }
                return
            }
            else {
            }
        }
        for operand in self.simple(e) {
            match operand {
                At(loc) {
                    self.float_load(XMM0, loc)
                    return
                }
                else {
                }
            }
        }
        var field = self.float_field(e, RCX)
        if field.len() > 0 {
            self.asm.sse_load(SSE_MOV, XMM0, field[0], field[1])
            return
        }
        self.expr(e)
        self.asm.movq_in(XMM0, RAX)
    }

    // `lhs op rhs` on floats, into XMM0.
    fn float_binary(self, op: int, lhs: ast.Expr, rhs: ast.Expr) {
        // When the left side is a plain read and the right side a
        // computation that runs no code of the program, the right side goes
        // first: nothing has to wait on the stack.
        var leaf = false
        match lhs.kind {
            Ident(_), Float(_), Field(_, _, _, _), Index(_, _) {
                leaf = true
            }
            else {
            }
        }
        var direct = false
        var rhs_float = false
        match rhs.kind {
            Field(obj, _, _, _) {
                direct = self.local(obj).len() > 0
            }
            Float(_) {
                rhs_float = true
            }
            else {
            }
        }
        if leaf && !direct && self.simple(rhs).len() == 0 && !rhs_float && self.is_pure(lhs) && self.is_pure(rhs) {
            self.float(rhs)
            self.asm.sse(SSE_MOV, XMM1, XMM0)
            self.float(lhs)
            self.asm.sse(op, XMM0, XMM1)
            return
        }
        self.float(lhs)
        var field = self.float_field(rhs, RCX)
        if field.len() > 0 {
            self.asm.sse_load(op, XMM0, field[0], field[1])
            return
        }
        for operand in self.simple(rhs) {
            match operand {
                At(loc) {
                    match loc {
                        Reg(r) {
                            self.asm.movq_in(XMM1, r)
                            self.asm.sse(op, XMM0, XMM1)
                        }
                        Frame(offset) {
                            if self.in_xmm.has(offset) {
                                self.asm.sse(op, XMM0, self.in_xmm[offset])
                            } else {
                                self.asm.sse_load(op, XMM0, RBP, offset)
                            }
                        }
                        Global(offset) {
                            self.asm.sse_load(op, XMM0, R15, offset)
                        }
                    }
                    return
                }
                else {
                }
            }
        }
        match rhs.kind {
            Float(x) {
                self.asm.mov_imm(RAX, float_bits(x))
                self.asm.movq_in(XMM1, RAX)
                self.asm.sse(op, XMM0, XMM1)
            }
            else {
                self.float_second(rhs)
                self.asm.sse(op, XMM0, XMM1)
            }
        }
    }

    // `dst = dst op e`, when `e` is a variable or a field that can be used
    // where it is. Returns false, having done nothing, when it is not.
    fn float_apply(self, op: int, dst: int, e: ast.Expr) -> bool {
        var operand = self.simple(e)
        if operand.len() > 0 {
            match operand[0] {
                At(loc) {
                    match loc {
                        Frame(offset) {
                            if self.in_xmm.has(offset) {
                                self.asm.sse(op, dst, self.in_xmm[offset])
                            } else {
                                self.asm.sse_load(op, dst, RBP, offset)
                            }
                            return true
                        }
                        Global(offset) {
                            self.asm.sse_load(op, dst, R15, offset)
                            return true
                        }
                        else {
                            return false
                        }
                    }
                }
                else {
                    return false
                }
            }
        }
        var field = self.float_field(e, RCX)
        if field.len() == 0 {
            return false
        }
        self.asm.sse_load(op, dst, field[0], field[1])
        return true
    }

    // Whether `float_apply` can use `e`.
    fn float_direct(self, e: ast.Expr) -> bool {
        var operand = self.simple(e)
        if operand.len() > 0 {
            match operand[0] {
                At(loc) {
                    match loc {
                        Reg(_) {
                            return false
                        }
                        else {
                            return true
                        }
                    }
                }
                else {
                    return false
                }
            }
        }
        match e.kind {
            Field(obj, name, _, _) {
                return self.ty(e) == checker.Type.Float && self.local(obj).len() > 0 && self.field_offset(obj, name).len() > 0
            }
            else {
                return false
            }
        }
    }

    // With a first operand in XMM0: evaluates `e` into XMM1, keeping XMM0.
    fn float_second(self, e: ast.Expr) {
        // `x * y`, with both at hand, is computed in XMM1 directly.
        match e.kind {
            Binary(op, lhs, rhs) {
                if is_float_op(op) && self.ty(e) == checker.Type.Float && self.float_direct(lhs) && self.float_direct(rhs) {
                    self.float_apply(SSE_MOV, XMM1, lhs)
                    self.float_apply(sse_of(op), XMM1, rhs)
                    return
                }
            }
            else {
            }
        }
        for operand in self.simple(e) {
            match operand {
                At(loc) {
                    self.float_load(XMM1, loc)
                    return
                }
                else {
                }
            }
        }
        match e.kind {
            Float(x) {
                self.asm.mov_imm(RAX, float_bits(x))
                self.asm.movq_in(XMM1, RAX)
            }
            else {
                // Computing it uses XMM0, and may call functions: the first
                // operand waits on the stack.
                self.asm.movq_out(RAX, XMM0)
                self.asm.push(RAX)
                self.float(e)
                self.asm.sse(SSE_MOV, XMM1, XMM0)
                self.asm.pop(RAX)
                self.asm.movq_in(XMM0, RAX)
            }
        }
    }

    // Compares two floats and returns the condition under which `lhs op rhs`
    // holds. For E and NE the caller must also look at the parity flag, set
    // when one of them is not a number; the other conditions are false by
    // themselves in that case.
    fn float_compare(self, op: ast.BinOp, lhs: ast.Expr, rhs: ast.Expr) -> int {
        self.float(lhs)
        self.float_second(rhs)
        // `a < b` is "b is above a".
        if op == ast.BinOp.Lt || op == ast.BinOp.Le {
            self.asm.ucomisd(XMM1, XMM0)
        } else {
            self.asm.ucomisd(XMM0, XMM1)
        }
        if op == ast.BinOp.Lt || op == ast.BinOp.Gt {
            return CC_A
        }
        if op == ast.BinOp.Le || op == ast.BinOp.Ge {
            return CC_AE
        }
        if op == ast.BinOp.Eq {
            return CC_E
        }
        return CC_NE
    }

    fn string_method(self, e: ast.Expr, obj: ast.Expr, name: string, args: [ast.Expr]) {
        var text = Arg.Borrow(obj)
        var strings = Arg.Descriptor(checker.Type.List(checker.Type.Str))
        if name == "len" {
            self.call_rt("__rt_str_len", [text], true)
        } else if name == "upper" {
            self.call_rt("__rt_str_upper", [text], true)
        } else if name == "lower" {
            self.call_rt("__rt_str_lower", [text], true)
        } else if name == "trim" {
            self.call_rt("__rt_str_trim", [text], true)
        } else if name == "contains" {
            self.call_rt("__rt_str_contains", [text, Arg.Borrow(args[0])], true)
        } else if name == "starts_with" {
            self.call_rt("__rt_str_starts", [text, Arg.Borrow(args[0])], true)
        } else if name == "ends_with" {
            self.call_rt("__rt_str_ends", [text, Arg.Borrow(args[0])], true)
        } else if name == "index_of" {
            self.call_rt("__rt_str_index_of", [text, Arg.Borrow(args[0])], true)
        } else if name == "slice" {
            self.call_rt("__rt_str_slice", [text, Arg.Value(args[0]), Arg.Value(args[1])], true)
        } else if name == "replace" {
            self.call_rt("__rt_str_replace", [text, Arg.Borrow(args[0]), Arg.Borrow(args[1])], true)
        } else if name == "split" {
            self.call_rt("__rt_str_split", [text, Arg.Borrow(args[0]), strings], true)
        } else if name == "chars" {
            self.call_rt("__rt_str_chars", [text, strings], true)
        } else if name == "repeat" {
            self.call_rt("__rt_str_repeat", [text, Arg.Value(args[0])], true)
        } else {
            self.unsupported(e.start, e.end, "calls to the string method `" + name + "`")
        }
    }

    // A value of an enum: the position of its variant, then what it carries.
    fn variant(self, e: ast.Expr, name: string, index: int) {
        var args: [ast.Expr] = []
        match e.kind {
            Call(_, call_args) {
                args = call_args
            }
            else {
            }
        }
        if args.len() == 0 {
            var key = name + "#" + str(index)
            var label = -1
            if self.plain_variants.has(key) {
                label = self.plain_variants[key]
            } else {
                label = self.asm.new_label()
                self.plain_variants[key] = label
                self.pending_variants.push(PendingVariant{name: name, index: index, label: label})
            }
            self.asm.lea(RAX, label)
            return
        }
        var td = self.descriptor(checker.Type.Enum(name))
        self.asm.lea(RAX, td)
        self.asm.push(RAX)
        self.asm.push_imm(16 + 8 * args.len())
        self.call_runtime("__rt_new", 2)
        self.asm.store_imm(RAX, 8, index)
        self.asm.push(RAX)
        for i in 0..args.len() {
            self.expr(args[i])
            self.asm.load(RCX, RSP, 0)
            self.asm.store(RCX, 16 + 8 * i, RAX)
        }
        self.asm.pop(RAX)
    }

    // `for v in channel`: receives until the channel is closed and empty.
    fn for_chan(self, name: string, at: int, iter: ast.Expr, body: ast.Block, elem: checker.Type) {
        var top = self.asm.new_label()
        var next = self.asm.new_label()
        var end = self.asm.new_label()
        var outer: [Var] = []
        self.scopes.push(outer)
        self.expr(iter)
        var channel = self.declare("<channel>", plan.var_key(at, plan.SUBJECT), self.ty(iter))
        self.store_loc(channel, RAX)

        self.asm.bind(top)
        self.load_loc(RAX, channel)
        self.asm.push(RAX)
        self.call_runtime("__rt_chan_take", 1)
        self.asm.alu_store_imm(ALU_CMP, R15, CHAN_OK, 0)
        self.asm.jcc(CC_E, end)

        // Inner scope: the loop variable, released after each turn.
        var inner: [Var] = []
        self.scopes.push(inner)
        var item = self.declare(name, plan.var_key(at, plan.NAMED), elem)
        self.store_loc(item, RAX)
        var depth = self.scopes.len()
        self.loops.push(Loop{next: next, end: end, continue_from: depth, break_from: depth - 1})
        self.block(body)
        self.loops.remove(self.loops.len() - 1)

        self.asm.bind(next)
        self.release_scopes(depth - 1)
        self.scopes.remove(self.scopes.len() - 1)
        self.asm.jmp(top)

        self.asm.bind(end)
        self.release_scopes(self.scopes.len() - 1)
        self.scopes.remove(self.scopes.len() - 1)
    }

    // Whether evaluating `e` lets other tasks run (in the JavaScript target:
    // whether it contains an `await`). Lambdas are functions of their own.
    fn awaits(self, e: ast.Expr) -> bool {
        match e.kind {
            Recv(_) {
                return true
            }
            Call(callee, args) {
                var waits = true
                if self.an.calls.has(e.id) {
                    match self.an.calls[e.id] {
                        Fn(name) {
                            waits = self.an.async_keys.has(checker.fn_key(name))
                        }
                        Method(strukt, name) {
                            waits = self.an.async_keys.has(checker.method_key(strukt, name))
                        }
                        Dynamic {
                            waits = true
                        }
                        Builtin(name) {
                            waits = name == "sleep"
                        }
                        BuiltinMethod(_, name) {
                            waits = name == "map" || name == "filter" || name == "sort_by"
                        }
                    }
                }
                if waits || self.awaits(callee) {
                    return true
                }
                for a in args {
                    if self.awaits(a) {
                        return true
                    }
                }
                return false
            }
            Str(parts) {
                for p in parts {
                    match p {
                        Code(inner) {
                            if self.awaits(inner) {
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
                    if self.awaits(item) {
                        return true
                    }
                }
                return false
            }
            Map(entries) {
                for entry in entries {
                    if self.awaits(entry.key) || self.awaits(entry.value) {
                        return true
                    }
                }
                return false
            }
            StructLit(_, _, _, fields) {
                for f in fields {
                    if self.awaits(f.value) {
                        return true
                    }
                }
                return false
            }
            Unary(_, inner) {
                return self.awaits(inner)
            }
            Try(inner) {
                return self.awaits(inner)
            }
            Catch(inner, _, _, _, _) {
                return self.awaits(inner)
            }
            Field(obj, _, _, _) {
                return self.awaits(obj)
            }
            Binary(_, lhs, rhs) {
                return self.awaits(lhs) || self.awaits(rhs)
            }
            Index(obj, index) {
                return self.awaits(obj) || self.awaits(index)
            }
            Range(lo, hi) {
                return self.awaits(lo) || self.awaits(hi)
            }
            Or(inner, default) {
                return self.awaits(inner) || self.awaits(default)
            }
            ChanNew(_, cap) {
                for c in cap {
                    if self.awaits(c) {
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

    // Where the JavaScript target has an `await`: the tasks that are ready
    // get to run before this one goes on. Keeps RAX and RDX (a result, an
    // error). Costs nothing in a program without `fork`.
    fn yield_point(self) {
        if !self.an.has_forks {
            return
        }
        self.asm.alu_store_imm(ALU_CMP, R15, READY_TASKS, 0)
        var alone = self.asm.jcc_short(CC_E)
        self.asm.push(RAX)
        self.asm.push(RDX)
        self.call_runtime("__rt_yield", 0)
        self.asm.pop(RDX)
        self.asm.pop(RAX)
        self.asm.bind_short(alone)
    }

    // `for c in text`: one character per turn. The loop keeps a position in
    // bytes, so that a text of any length is walked in a single pass.
    fn for_str(self, name: string, at: int, iter: ast.Expr, body: ast.Block) {
        var top = self.asm.new_label()
        var next = self.asm.new_label()
        var check = self.asm.new_label()
        var end = self.asm.new_label()
        // Outer scope: the string (kept alive for the whole loop) and the position in it.
        var outer: [Var] = []
        self.scopes.push(outer)
        self.expr(iter)
        var text = self.declare("<string>", plan.var_key(at, plan.SUBJECT), checker.Type.Str)
        self.store_loc(text, RAX)
        var position = self.home(plan.var_key(at, plan.COUNTER))
        self.asm.mov_imm(RAX, 0)
        self.store_loc(position, RAX)
        self.asm.jmp(check)

        self.asm.bind(top)
        self.load_loc(RAX, text)
        self.asm.push(RAX)
        self.load_loc(RAX, position)
        self.asm.push(RAX)
        self.call_runtime("__rt_char_at", 2)
        // The next turn starts after this character, however many bytes it takes.
        self.asm.load32(RCX, RAX, 8)
        self.load_loc(RDX, position)
        self.asm.alu(ALU_ADD, RDX, RCX)
        self.store_loc(position, RDX)

        // Inner scope: the loop variable, released after each turn.
        var inner: [Var] = []
        self.scopes.push(inner)
        var item = self.declare(name, plan.var_key(at, plan.NAMED), checker.Type.Str)
        self.store_loc(item, RAX)
        var depth = self.scopes.len()
        self.loops.push(Loop{next: next, end: end, continue_from: depth, break_from: depth - 1})
        self.block(body)
        self.loops.remove(self.loops.len() - 1)

        self.asm.bind(next)
        self.release_scopes(depth - 1)
        self.scopes.remove(self.scopes.len() - 1)
        self.asm.bind(check)
        self.load_loc(RCX, text)
        self.asm.load32(RCX, RCX, 8)
        self.load_loc(RAX, position)
        self.asm.alu(ALU_CMP, RAX, RCX)
        self.asm.jcc(CC_L, top)

        self.asm.bind(end)
        self.release_scopes(self.scopes.len() - 1)
        self.scopes.remove(self.scopes.len() - 1)
    }

    // An element given to a list: moved into it (`moved`) or only shown to it.
    fn element(self, arg: ast.Expr, moved: bool) -> Arg {
        if !is_ref(self.ty(arg)) {
            return Arg.Value(arg)
        }
        if moved {
            return Arg.Move(arg)
        }
        return Arg.Borrow(arg)
    }

    fn list_method(self, e: ast.Expr, obj: ast.Expr, name: string, args: [ast.Expr]) {
        if name == "len" {
            if self.is_place(obj) {
                self.place(obj)
                self.asm.load(RAX, RAX, LIST_LEN)
            } else {
                var owned = self.operand(obj)
                if owned {
                    self.asm.push(RAX)
                }
                self.asm.load(RAX, RAX, LIST_LEN)
                if owned {
                    self.release_saved()
                }
            }
        } else if name == "push" {
            var list = self.local(obj)
            if list.len() > 0 {
                // The list is in a variable: when it has room, the value
                // is stored right here. It moves into the list.
                self.expr(args[0])
                self.load_loc(RCX, list[0].loc)
                self.asm.load(RDX, RCX, LIST_LEN)
                self.asm.alu_load(ALU_CMP, RDX, RCX, LIST_CAP)
                var full = self.asm.jcc_short(CC_E)
                self.asm.load(R8, RCX, LIST_DATA)
                self.asm.store_indexed(R8, RDX, RAX)
                self.asm.alu_imm(ALU_ADD, RDX, 1)
                self.asm.store(RCX, LIST_LEN, RDX)
                var done = self.asm.jmp_short()
                self.asm.bind_short(full)
                self.asm.push(RCX)
                self.asm.push(RAX)
                self.call_runtime("__rt_list_push", 2)
                self.asm.bind_short(done)
                return
            }
            self.call_rt("__rt_list_push", [Arg.Borrow(obj), self.element(args[0], true)], false)
        } else if name == "insert" {
            self.call_rt("__rt_list_insert", [Arg.Borrow(obj), Arg.Value(args[0]), self.element(args[1], true)], false)
        } else if name == "remove" {
            self.call_rt("__rt_list_remove", [Arg.Borrow(obj), Arg.Value(args[0])], true)
        } else if name == "pop" {
            self.call_rt_fallible("__rt_list_pop", [Arg.Borrow(obj)], true)
        } else if name == "first" {
            self.call_rt_fallible("__rt_list_first", [Arg.Borrow(obj)], true)
        } else if name == "last" {
            self.call_rt_fallible("__rt_list_last", [Arg.Borrow(obj)], true)
        } else if name == "clear" {
            self.call_rt("__rt_list_clear", [Arg.Borrow(obj)], false)
        } else if name == "contains" || name == "index_of" {
            var function = "__rt_list_index_of"
            if name == "contains" {
                function = "__rt_list_contains"
            }
            self.call_rt(function, [Arg.Borrow(obj), self.element(args[0], false)], true)
        } else if name == "slice" {
            self.call_rt("__rt_list_slice", [Arg.Borrow(obj), Arg.Value(args[0]), Arg.Value(args[1])], true)
        } else if name == "reverse" {
            self.call_rt("__rt_list_reverse", [Arg.Borrow(obj)], true)
        } else if name == "sort" {
            self.call_rt("__rt_list_sort", [Arg.Borrow(obj)], true)
        } else if name == "join" {
            self.call_rt("__rt_list_join", [Arg.Borrow(obj), Arg.Borrow(args[0])], true)
        } else if name == "map" || name == "filter" || name == "sort_by" {
            // These run code of the program, the function they are given:
            // nothing may be borrowed from a place it could change.
            var owned = [self.push_arg(obj), self.push_arg(args[0]), false]
            var extra = checker.Type.Int
            if name == "map" {
                extra = self.ty(e)
            } else {
                match self.ty(args[0]) {
                    Fn(sig) {
                        extra = sig.ret
                    }
                    else {
                    }
                }
            }
            var td = self.descriptor(extra)
            self.asm.lea(RAX, td)
            self.asm.push(RAX)
            self.call_runtime("__rt_list_" + name, 0)
            self.drop_args(owned, true)
            self.yield_point()
        } else {
            self.unsupported(e.start, e.end, "calls to the list method `" + name + "`")
        }
    }

    fn builtin(self, name: string, e: ast.Expr, args: [ast.Expr]) {
        if name == "print" {
            // print(a, b) writes "a b" and a line break; interpolated
            // strings are written piece by piece, without being built.
            var pieces: [Piece] = []
            for i in 0..args.len() {
                if i > 0 {
                    add_text(pieces, " ")
                }
                var arg = args[i]
                match arg.kind {
                    Str(parts) {
                        for part in parts {
                            match part {
                                Lit(s) {
                                    add_text(pieces, s)
                                }
                                Code(inner) {
                                    pieces.push(Piece.Code(inner))
                                }
                            }
                        }
                    }
                    else {
                        pieces.push(Piece.Code(arg))
                    }
                }
            }
            var pushed = self.push_pieces(pieces)
            self.asm.mov(RAX, RSP)
            self.asm.push(RAX)
            self.asm.push_imm(pieces.len())
            self.call_runtime("__rt_print_pieces", 2)
            self.drop_pieces(pushed, false)
        } else if name == "str" {
            if self.ty(args[0]) == checker.Type.Str {
                self.expr(args[0])
            } else {
                self.to_str(args[0])
            }
        } else if name == "parse_int" {
            self.call_rt_fallible("__rt_parse_int", [Arg.Borrow(args[0])], true)
        } else if name == "exit" {
            self.call_rt("__rt_exit", [Arg.Value(args[0])], false)
        } else if name == "panic" {
            self.call_rt("__rt_panic", [Arg.Borrow(args[0])], false)
        } else if name == "expect" {
            var fine = self.asm.new_label()
            self.cond_jump(args[0], fine, true)
            var place = self.string("an `expect`")
            self.asm.lea(RAX, place)
            self.asm.push(RAX)
            self.call_runtime("__rt_expect_failed", 1)
            self.asm.bind(fine)
        } else if name == "float" || name == "sqrt" {
            self.float(e)
            self.asm.movq_out(RAX, XMM0)
        } else if name == "int" {
            if self.ty(args[0]) == checker.Type.Float {
                self.float(args[0])
                self.asm.cvttsd2si(RAX, XMM0)
            } else {
                self.expr(args[0])
            }
        } else if name == "pow" {
            self.call_rt("__rt_pow", [Arg.Value(args[0]), Arg.Value(args[1])], true)
        } else if name == "floor" {
            self.call_rt("__rt_floor", [Arg.Value(args[0])], true)
        } else if name == "ceil" {
            self.call_rt("__rt_ceil", [Arg.Value(args[0])], true)
        } else if name == "round" {
            self.call_rt("__rt_round_float", [Arg.Value(args[0])], true)
        } else if name == "parse_float" {
            self.call_rt_fallible("__rt_parse_float", [Arg.Borrow(args[0])], true)
        } else if name == "args" {
            self.call_rt("__rt_args", [Arg.Descriptor(checker.Type.List(checker.Type.Str))], true)
        } else if name == "env" {
            self.call_rt_fallible("__rt_env", [Arg.Borrow(args[0])], true)
        } else if name == "read_file" {
            self.call_rt_fallible("__rt_read_file", [Arg.Borrow(args[0])], true)
        } else if name == "write_file" || name == "append_file" {
            var flags = 1089
            if name == "write_file" {
                flags = 577
            }
            self.call_rt_fallible("__rt_write_file", [Arg.Borrow(args[0]), Arg.Borrow(args[1]), Arg.Const(flags)], false)
        } else if name == "file_exists" {
            self.call_rt("__rt_file_exists", [Arg.Borrow(args[0])], true)
        } else if name == "set_executable" {
            self.call_rt_fallible("__rt_set_executable", [Arg.Borrow(args[0])], false)
        } else if name == "input" {
            self.call_rt("__rt_input", [Arg.Borrow(args[0])], true)
        } else if name == "now" {
            self.call_rt("__rt_now", [], true)
        } else if name == "sleep" {
            if self.an.has_forks {
                self.call_rt("__rt_task_sleep", [Arg.Value(args[0])], false)
            } else {
                self.call_rt("__rt_sleep", [Arg.Value(args[0])], false)
            }
        } else if name == "weak" {
            if args.len() == 0 {
                self.call_rt("__rt_weak_none", [Arg.Descriptor(self.ty(e))], true)
            } else {
                var table = checker.Type.Map(checker.Type.Int, checker.Type.Int)
                self.call_rt("__rt_weak", [Arg.Borrow(args[0]), Arg.Descriptor(self.ty(e)), Arg.Descriptor(table)], true)
            }
        } else if name == "__tag" {
            // What `match` is rewritten with (see desugar.ox): the position
            // of the variant of an enum value, and one of the values it carries.
            self.operand(args[0])
            self.asm.load(RAX, RAX, 8)
        } else if name == "__field" {
            match args[1].kind {
                Int(which) {
                    self.operand(args[0])
                    self.asm.load(RAX, RAX, 16 + 8 * which)
                    if is_ref(self.ty(e)) {
                        self.retain(RAX)
                    }
                }
                else {
                }
            }
        } else if name == "__fork" {
            // The closure belongs to the new task from here on.
            self.expr(args[0])
            self.asm.push(RAX)
            self.call_runtime("__rt_fork", 1)
        } else if name == "random" {
            self.call_rt("__rt_random", [], true)
        } else if name == "random_int" {
            self.call_rt("__rt_random_int", [Arg.Value(args[0]), Arg.Value(args[1])], true)
        } else if name == "abs" && self.ty(e) == checker.Type.Float {
            // Clear the sign bit.
            self.expr(args[0])
            self.asm.shift(SHIFT_LEFT, RAX, 1)
            self.asm.shift(SHIFT_RIGHT, RAX, 1)
        } else if (name == "min" || name == "max") && self.ty(e) == checker.Type.Float {
            var function = "__rt_float_max"
            if name == "min" {
                function = "__rt_float_min"
            }
            self.call_rt(function, [Arg.Value(args[0]), Arg.Value(args[1])], true)
        } else if name == "abs" {
            self.expr(args[0])
            self.asm.alu_imm(ALU_CMP, RAX, 0)
            var positive = self.asm.jcc_short(CC_GE)
            self.asm.neg(RAX)
            self.asm.bind_short(positive)
        } else if name == "min" || name == "max" {
            var keep = CC_GE
            if name == "min" {
                keep = CC_LE
            }
            var other = self.simple(args[1])
            if other.len() > 0 {
                self.expr(args[0])
                self.operand_alu(ALU_CMP, RAX, other[0])
                var done = self.asm.jcc_short(keep)
                self.load_operand(RAX, other[0])
                self.asm.bind_short(done)
            } else {
                self.expr(args[0])
                self.asm.push(RAX)
                self.expr(args[1])
                self.asm.mov(RCX, RAX)
                self.asm.pop(RAX)
                self.asm.alu(ALU_CMP, RAX, RCX)
                var done = self.asm.jcc_short(keep)
                self.asm.mov(RAX, RCX)
                self.asm.bind_short(done)
            }
        } else {
            self.low_level(name, e, args)
        }
    }

    // ---- low-level operations reserved to the runtime ----
    fn low_level(self, name: string, e: ast.Expr, args: [ast.Expr]) {
        if name == "__syscall" {
            // RSI and RDI carry arguments but may hold variables: keep them.
            self.asm.push(RSI)
            self.asm.push(RDI)
            for arg in args {
                self.push_value(arg)
            }
            for r in [R9, R8, R10, RDX, RSI, RDI, RAX] {
                self.asm.pop(r)
            }
            self.asm.syscall()
            self.asm.pop(RDI)
            self.asm.pop(RSI)
        } else if name == "__load8" || name == "__load32" || name == "__load64" {
            var at = self.address(args[0])
            if name == "__load8" {
                self.asm.load8(RAX, at[0], at[1])
            } else if name == "__load32" {
                self.asm.load32(RAX, at[0], at[1])
            } else {
                self.asm.load(RAX, at[0], at[1])
            }
        } else if name == "__store8" || name == "__store32" || name == "__store64" {
            var base = RAX
            var offset = 0
            var source = RAX
            var operand = self.simple(args[1])
            if operand.len() > 0 {
                var is_imm = false
                var imm = 0
                match operand[0] {
                    Imm(v) {
                        is_imm = true
                        imm = v
                    }
                    else {
                    }
                }
                if is_imm && name == "__store64" {
                    var at = self.address(args[0])
                    self.asm.store_imm(at[0], at[1], imm)
                    return
                }
                var at = self.address(args[0])
                base = at[0]
                offset = at[1]
                var r = operand_reg(operand[0])
                if r >= 0 {
                    source = r
                } else {
                    self.load_operand(RCX, operand[0])
                    source = RCX
                }
            } else {
                var at = self.address(args[0])
                offset = at[1]
                if at[0] == RAX {
                    // The address had to be computed: it waits on the stack.
                    self.asm.push(RAX)
                    self.expr(args[1])
                    self.asm.pop(RCX)
                    base = RCX
                } else {
                    self.expr(args[1])
                    base = at[0]
                }
                source = RAX
            }
            if name == "__store8" {
                self.asm.store8(base, offset, source)
            } else if name == "__store32" {
                self.asm.store32(base, offset, source)
            } else {
                self.asm.store(base, offset, source)
            }
        } else if name == "__copy" {
            self.push_value(args[0])
            self.push_value(args[1])
            var count = self.simple(args[2])
            if count.len() > 0 {
                self.load_operand(RCX, count[0])
            } else {
                self.expr(args[2])
                self.asm.mov(RCX, RAX)
            }
            // RSI and RDI may hold variables: they are kept in RAX and RDX.
            self.asm.mov(RAX, RSI)
            self.asm.mov(RDX, RDI)
            self.asm.pop(RSI)
            self.asm.pop(RDI)
            self.copy_bytes()
            self.asm.mov(RSI, RAX)
            self.asm.mov(RDI, RDX)
        } else if name == "bit_not" {
            self.expr(args[0])
            self.asm.alu_imm(ALU_XOR, RAX, -1)
        } else if name == "ord" {
            self.call_rt("__rt_ord", [Arg.Borrow(args[0])], true)
        } else if name == "chr" {
            self.call_rt("__rt_chr", [Arg.Value(args[0])], true)
        } else if name == "bytes" {
            self.call_rt("__rt_bytes", [Arg.Borrow(args[0]), Arg.Descriptor(self.ty(e))], true)
        } else if name == "from_bytes" {
            self.call_rt("__rt_from_bytes", [Arg.Borrow(args[0])], true)
        } else if name == "read_bytes" {
            self.call_rt_fallible("__rt_read_bytes", [Arg.Borrow(args[0]), Arg.Descriptor(self.ty(e))], true)
        } else if name == "write_bytes" {
            self.call_rt_fallible("__rt_write_bytes", [Arg.Borrow(args[0]), Arg.Borrow(args[1])], false)
        } else if name == "__and" || name == "bit_and" {
            self.expr(args[0])
            var operand = self.simple(args[1])
            if operand.len() > 0 {
                self.operand_alu(ALU_AND, RAX, operand[0])
            } else {
                self.asm.push(RAX)
                self.expr(args[1])
                self.asm.pop(RCX)
                self.asm.alu(ALU_AND, RAX, RCX)
            }
        } else if name == "__or" || name == "__xor" || name == "bit_or" || name == "bit_xor" {
            var alu = ALU_XOR
            if name.ends_with("_or") {
                alu = ALU_OR
            }
            self.expr(args[0])
            self.asm.push(RAX)
            self.expr(args[1])
            self.asm.pop(RCX)
            self.asm.alu(alu, RAX, RCX)
        } else if name == "__shl" || name == "__shr" || name == "__sar" || name == "shift_left" || name == "shift_right" {
            var kind = SHIFT_RIGHT_SIGNED
            if name == "__shl" || name == "shift_left" {
                kind = SHIFT_LEFT
            } else if name == "__shr" {
                kind = SHIFT_RIGHT
            }
            match args[1].kind {
                Int(count) {
                    self.expr(args[0])
                    self.asm.shift(kind, RAX, count)
                }
                else {
                    self.expr(args[0])
                    self.asm.push(RAX)
                    self.expr(args[1])
                    self.asm.mov(RCX, RAX)
                    self.asm.pop(RAX)
                    self.asm.shift_cl(kind, RAX)
                }
            }
        } else if name == "__bits" || name == "__float" || name == "float_bits" || name == "float_from_bits" {
            // A float and its bits are the same 64 bits: only the type changes.
            self.expr(args[0])
        } else if name == "__call1" {
            // Calls a closure with one argument.
            self.expr(args[0])
            self.asm.push(RAX)
            self.expr(args[1])
            self.asm.push(RAX)
            self.asm.load(R10, RSP, 8)
            self.asm.call_mem(R10, FIELDS)
            self.reload_floats()
            self.asm.alu_imm(ALU_ADD, RSP, 16)
        } else if name == "__yield" {
            self.yield_point()
        } else if name == "__switch" {
            self.expr(args[0])
            self.asm.push(RAX)
            self.expr(args[1])
            self.asm.mov(RCX, RAX)
            self.asm.pop(RAX)
            if self.switch < 0 {
                self.switch = self.asm.new_label()
            }
            self.asm.call(self.switch)
            self.reload_floats()
        } else if name == "__fault_entry" {
            if self.fault_entry < 0 {
                self.fault_entry = self.asm.new_label()
            }
            self.asm.lea(RAX, self.fault_entry)
        } else if name == "__task_entry" {
            if self.task_entry < 0 {
                self.task_entry = self.asm.new_label()
            }
            self.asm.lea(RAX, self.task_entry)
        } else if name == "__unwind" {
            self.asm.load(RSP, R15, TEST_STACK)
            self.asm.jmp_mem(R15, TEST_RESUME)
        } else if name == "__state" {
            self.asm.mov(RAX, R15)
        } else if name == "__td_string" {
            var td = self.descriptor(checker.Type.Str)
            self.asm.lea(RAX, td)
        } else if name == "__str_ptr" {
            // The address of a string, without taking a reference.
            if self.local(args[0]).len() == 0 {
                self.unsupported(e.start, e.end, "`__str_ptr` on anything but a local variable")
            }
            self.operand(args[0])
        } else if name == "__ptr_str" {
            // An address the runtime owns becomes an owned string.
            self.expr(args[0])
        } else {
            self.unsupported(e.start, e.end, "calls to `" + name + "`")
        }
    }

    // Copies RCX bytes from [RSI] to [RDI]; R8 and R9 are scratch. Most
    // copies are a few bytes long (short strings), so those are done with
    // two possibly overlapping moves: the first and the last 8 (or 4) bytes.
    // Both are read before anything is written, so the areas may overlap.
    fn copy_bytes(self) {
        self.asm.alu_imm(ALU_CMP, RCX, 16)
        var long = self.asm.jcc_short(CC_G)
        self.asm.alu_imm(ALU_CMP, RCX, 8)
        var under_8 = self.asm.jcc_short(CC_L)
        self.asm.load(R8, RSI, 0)
        self.asm.load_at(R9, RSI, RCX, -8, true)
        self.asm.store(RDI, 0, R8)
        self.asm.store_at(RDI, RCX, -8, R9, true)
        var done_8 = self.asm.jmp_short()

        self.asm.bind_short(under_8)
        self.asm.alu_imm(ALU_CMP, RCX, 4)
        var under_4 = self.asm.jcc_short(CC_L)
        self.asm.load32(R8, RSI, 0)
        self.asm.load_at(R9, RSI, RCX, -4, false)
        self.asm.store32(RDI, 0, R8)
        self.asm.store_at(RDI, RCX, -4, R9, false)
        var done_4 = self.asm.jmp_short()

        self.asm.bind_short(under_4)
        self.asm.test(RCX, RCX)
        var done_0 = self.asm.jcc_short(CC_E)
        var next = self.asm.pos()
        self.asm.load8(R8, RSI, 0)
        self.asm.store8(RDI, 0, R8)
        self.asm.alu_imm(ALU_ADD, RSI, 1)
        self.asm.alu_imm(ALU_ADD, RDI, 1)
        self.asm.alu_imm(ALU_SUB, RCX, 1)
        self.asm.jcc_back(CC_NE, next)
        var done_bytes = self.asm.jmp_short()

        self.asm.bind_short(long)
        self.asm.rep_movsb()
        self.asm.bind_short(done_8)
        self.asm.bind_short(done_4)
        self.asm.bind_short(done_0)
        self.asm.bind_short(done_bytes)
    }

    // Prepares the address `e` for a memory access: returns the register
    // that holds its base and the constant to add. `p + 8` with `p` in a
    // register needs no instruction at all.
    fn address(self, e: ast.Expr) -> [int] {
        var base = e
        var offset = 0
        match e.kind {
            Binary(op, lhs, rhs) {
                if op == ast.BinOp.Add {
                    match rhs.kind {
                        Int(k) {
                            if k >= -2147483648 && k <= 2147483647 {
                                base = lhs
                                offset = k
                            }
                        }
                        else {
                        }
                    }
                }
            }
            else {
            }
        }
        for operand in self.simple(base) {
            var r = operand_reg(operand)
            if r >= 0 {
                return [r, offset]
            }
        }
        self.expr(base)
        return [RAX, offset]
    }
}
