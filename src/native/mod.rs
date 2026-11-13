//! Native backend: AST + analysis -> x86-64 machine code in a Linux executable.
//!
//! VALUES. Every value is 64 bits wide: an integer, a boolean, or the address
//! of a heap object (string, list, struct). Object layouts and type
//! descriptors are documented at the top of `runtime.ox`.
//!
//! CODE SHAPE. An expression leaves its result in RAX; RCX, RDX and R8-R11 are
//! scratch. When both sides of an operation are complicated, the left one
//! waits on the stack. Operations with a constant or a variable on one side
//! are done directly, without going through the stack.
//!
//! VARIABLES. The most used variables of a function live in registers (see
//! `plan.rs`): RBX, R12, R13, R14, RSI and RDI. The others live in the stack
//! frame, addressed from RBP. R15 always holds the address of the runtime's
//! state, which is followed by the program's top-level variables.
//!
//! CALLS (a convention private to Onyx). The caller pushes the arguments from
//! first to last, calls, then removes them; the result comes back in RAX.
//! A function saves the variable registers it uses and restores them before
//! returning, so they survive calls; every other register may change.
//!
//! MEMORY. References are counted. The rules the generator follows:
//!   - evaluating an expression yields an *owned* reference: whoever asked for
//!     it must store it somewhere, hand it over, or release it;
//!   - a variable, a field and a list slot each own what they hold;
//!   - arguments are only *borrowed* by the function that receives them: the
//!     caller keeps them alive during the call. A local variable can be lent
//!     as is, without touching its count;
//!   - leaving a scope releases the variables declared in it.
//!
//! Only the functions that are reachable from `main` are compiled.

mod asm;
mod capture;
mod elf;
mod lower;
mod plan;
mod widen;

use crate::ast::*;
use crate::checker::{lambda_key, method_key, Analysis, CallKind, Recv, Type};
use crate::diagnostics::{Diagnostic, Span};
use asm::*;
use plan::{VarKey, COUNTER, NAMED, SUBJECT};
use std::collections::{HashMap, HashSet};

/// The runtime, written in Onyx and compiled into every native program.
pub const RUNTIME_SOURCE: &str = include_str!("runtime.ox");

/// Size of the runtime's state. The top-level variables, then the method
/// caches of interface calls, are stored right after it.
const STATE_SIZE: i32 = 4096;

// Offsets inside heap objects (see runtime.ox).
const COUNT: i32 = 0;
const DESCRIPTOR: i32 = 4;
const LIST_LEN: i32 = 8;
const LIST_CAP: i32 = 16;
const LIST_DATA: i32 = 24;
const FIELDS: i32 = 8;

/// Stack space in which the runtime writes the text of a number (see
/// `__rt_int_into` in runtime.ox).
const NUMBER_BUFFER: i32 = 40;

/// Registers that hold local variables.
const VARIABLE_REGS: [Reg; 6] = [RBX, R12, R13, R14, RSI, RDI];

/// Key of the `self` parameter of a method (its position is the method's name).
const SELF: u8 = 3;

pub fn generate(program: &mut Program, an: &mut Analysis, leak_check: bool) -> Result<Vec<u8>, Vec<Diagnostic>> {
    widen::widen(program, an);
    capture::capture(program, an);
    lower::lower(program, an);
    let (program, an) = (&*program, &*an);
    let mut g = Gen {
        an,
        asm: Asm::default(),
        diags: Vec::new(),
        items: HashMap::new(),
        labels: HashMap::new(),
        requested: HashSet::new(),
        queue: Vec::new(),
        globals: HashMap::new(),
        strings: HashMap::new(),
        descriptors: HashMap::new(),
        pending_descriptors: Vec::new(),
        pending_closures: Vec::new(),
        static_closures: HashMap::new(),
        pending_statics: Vec::new(),
        caches: 0,
        div_zero: None,
        index_oob: None,
        scopes: Vec::new(),
        regs: HashMap::new(),
        slots: 0,
        loops: Vec::new(),
        epilogue: None,
        at_tail: false,
        fallible: false,
        keep_error: false,
        rt_fallible: false,
    };

    // Every function gets a label. Its code is only generated when something refers to it.
    let mut global_order = Vec::new();
    let mut lambdas: Vec<&Expr> = Vec::new();
    for item in &program.items {
        match item {
            Item::Fn(f) => {
                let Some(sig) = an.fns.get(&f.name) else { continue };
                let params = f
                    .params
                    .iter()
                    .zip(&sig.params)
                    .map(|(p, ty)| ParamInfo { name: p.name.clone(), ty: ty.clone(), key: (p.span.start, NAMED), span: p.ty.span })
                    .collect();
                lambdas_in(&f.body, &mut lambdas);
                let item = FnItem { body: &f.body, fallible: f.fallible, span: f.name_span, params, ret: sig.ret.clone(), captures: Vec::new() };
                g.add_function(f.name.clone(), item);
            }
            Item::Struct(s) => {
                for m in &s.methods {
                    let sig = &an.structs[&s.name].methods[&m.name];
                    let mut params = vec![ParamInfo {
                        name: "self".to_string(),
                        ty: Type::Struct(s.name.clone()),
                        key: (m.name_span.start, SELF),
                        span: m.name_span,
                    }];
                    params.extend(m.params.iter().zip(&sig.params).map(|(p, ty)| ParamInfo {
                        name: p.name.clone(),
                        ty: ty.clone(),
                        key: (p.span.start, NAMED),
                        span: p.ty.span,
                    }));
                    lambdas_in(&m.body, &mut lambdas);
                    let item = FnItem { body: &m.body, fallible: m.fallible, span: m.name_span, params, ret: sig.ret.clone(), captures: Vec::new() };
                    g.add_function(method_key(&s.name, &m.name), item);
                }
            }
            Item::Global(Stmt { kind: StmtKind::Let { name, init, .. }, .. }) => {
                if let ExprKind::Lambda { .. } = &init.kind {
                    lambdas.push(init);
                }
                if let ExprKind::Lambda { body, .. } = &init.kind {
                    lambdas_in(body, &mut lambdas);
                }
                let offset = STATE_SIZE + 8 * global_order.len() as i32;
                g.globals.insert(name.clone(), (offset, g.ty(init)));
                global_order.push(name.clone());
            }
            _ => {}
        }
    }
    // A lambda is one more function, with a hidden extra: the closure it runs for.
    for lambda in lambdas {
        let ExprKind::Lambda { params, body, fallible, .. } = &lambda.kind else { continue };
        let Type::Fn(sig) = g.ty(lambda) else { continue };
        let params = params
            .iter()
            .zip(&sig.params)
            .map(|(p, ty)| ParamInfo { name: p.name.clone(), ty: ty.clone(), key: (p.span.start, NAMED), span: p.ty.span })
            .collect();
        let captures = an.captures.get(&lambda.id).cloned().unwrap_or_default();
        let item = FnItem { body, fallible: *fallible, span: lambda.span, params, ret: sig.ret.clone(), captures };
        g.add_function(lambda_key(lambda.id), item);
    }
    g.descriptor(&Type::Str);

    // Program entry: map the state, give the top-level variables their values, run main.
    let entry = g.asm.pos();
    g.asm.mov_imm(RAX, 9); // mmap(NULL, size, READ | WRITE, PRIVATE | ANONYMOUS, -1, 0)
    g.asm.mov_imm(RDI, 0);
    let state_size_at = g.asm.mov_imm32_patchable(RSI, 0);
    g.asm.mov_imm(RDX, 3);
    g.asm.mov_imm(R10, 0x22);
    g.asm.mov_imm(R8, -1);
    g.asm.mov_imm(R9, 0);
    g.asm.syscall();
    g.asm.mov(R15, RAX);
    g.asm.mov(RBP, RSP);
    for item in &program.items {
        if let Item::Global(Stmt { kind: StmtKind::Let { name, init, .. }, .. }) = item {
            let offset = g.globals[name].0;
            g.expr_into(init, Loc::Global(offset));
        }
    }
    if let Some(main) = g.items.get("main") {
        let can_fail = main.fallible;
        let label = g.function_label("main");
        g.asm.call(label);
        if can_fail {
            // An error that nobody handled ends the program.
            g.asm.test(RDX, RDX);
            let fine = g.asm.jcc_short(Cc::E);
            g.asm.push(RDX);
            g.call_runtime("__rt_main_failed", 0);
            g.asm.bind_short(fine);
        }
    }
    if leak_check {
        for name in global_order.iter().rev() {
            let (offset, ty) = g.globals[name].clone();
            if is_ref(&ty) {
                g.asm.load(RAX, R15, offset);
                g.release_rax();
            }
        }
        g.call_runtime("__rt_leak_check", 0);
    }
    g.asm.push_imm(0);
    g.call_runtime("__rt_exit", 0);

    // Compile what was asked for, which may ask for more.
    loop {
        if let Some(key) = g.queue.pop() {
            g.function(&key);
        } else if !(g.emit_stubs() || g.emit_descriptors()) {
            break;
        }
    }
    g.emit_strings();

    let state_bytes = STATE_SIZE as i64 + 8 * global_order.len() as i64 + 16 * g.caches as i64;
    g.asm.patch32(state_size_at, ((state_bytes + 4095) / 4096 * 4096) as i32);

    if !g.diags.is_empty() {
        g.diags.sort_by_key(|d| d.span.start);
        g.diags.dedup_by_key(|d| (d.span.start, d.message.clone()));
        return Err(g.diags);
    }
    Ok(elf::write(&g.asm.finish(elf::IMAGE_BASE), entry))
}

fn is_ref(ty: &Type) -> bool {
    matches!(ty, Type::Str | Type::Error | Type::List(_) | Type::Map(..) | Type::Struct(_) | Type::Interface(_) | Type::Fn(_))
}

fn supported(ty: &Type) -> bool {
    match ty {
        Type::Int | Type::Float | Type::Bool | Type::Str | Type::Error | Type::Void | Type::Range | Type::Unknown => true,
        Type::Struct(_) | Type::Interface(_) => true,
        Type::Fn(sig) => sig.params.iter().all(supported) && supported(&sig.ret),
        Type::List(elem) => supported(elem),
        Type::Map(key, value) => **key != Type::Float && supported(key) && supported(value),
        _ => false,
    }
}

/// The text of a string literal without interpolation.
fn plain(parts: &[StrPart]) -> Option<&str> {
    match parts {
        [] => Some(""),
        [StrPart::Lit(s)] => Some(s),
        _ => None,
    }
}

/// Does control never reach the end of this block?
fn leaves(block: &Block) -> bool {
    matches!(
        block.stmts.last().map(|s| &s.kind),
        Some(StmtKind::Return(_) | StmtKind::Break | StmtKind::Continue | StmtKind::Fail(_))
    )
}

fn cc_of(op: BinOp) -> Cc {
    match op {
        BinOp::Eq => Cc::E,
        BinOp::NotEq => Cc::Ne,
        BinOp::Lt => Cc::L,
        BinOp::Le => Cc::Le,
        BinOp::Gt => Cc::G,
        _ => Cc::Ge,
    }
}

/// For dividing by the constant `d` with a multiplication (Hacker's Delight,
/// "Signed division by constants"): returns `(magic, shift)` such that
/// `n / d` is `high64(magic * n)`, corrected by `n` when the signs of `magic`
/// and `d` differ, shifted right by `shift`, plus one when negative.
/// `d` must not be 0, 1 or -1.
fn magic_number(d: i64) -> (i64, u8) {
    const TWO63: u64 = 1 << 63;
    let ad = d.unsigned_abs();
    let t = TWO63 + ((d as u64) >> 63);
    let anc = t - 1 - t % ad;
    let mut p = 63;
    let mut q1 = TWO63 / anc;
    let mut r1 = TWO63 - q1 * anc;
    let mut q2 = TWO63 / ad;
    let mut r2 = TWO63 - q2 * ad;
    loop {
        p += 1;
        q1 = q1.wrapping_mul(2);
        r1 = r1.wrapping_mul(2);
        if r1 >= anc {
            q1 = q1.wrapping_add(1);
            r1 = r1.wrapping_sub(anc);
        }
        q2 = q2.wrapping_mul(2);
        r2 = r2.wrapping_mul(2);
        if r2 >= ad {
            q2 = q2.wrapping_add(1);
            r2 = r2.wrapping_sub(ad);
        }
        let delta = ad - r2;
        if !(q1 < delta || (q1 == delta && r1 == 0)) {
            break;
        }
    }
    let magic = q2.wrapping_add(1) as i64;
    (if d < 0 { magic.wrapping_neg() } else { magic }, (p - 64) as u8)
}

/// Where a variable lives.
#[derive(Clone, Copy, PartialEq)]
enum Loc {
    Reg(Reg),
    /// Offset from RBP: a parameter or a local variable.
    Frame(i32),
    /// Offset from R15: a top-level variable.
    Global(i32),
}

/// Something an instruction can use directly, without computing it first.
#[derive(Clone, Copy)]
enum Operand {
    Imm(i64),
    At(Loc),
}

struct Var {
    name: String,
    loc: Loc,
    is_ref: bool,
    /// The variable holds a reference of its own, released when it goes away.
    /// False for parameters, which are borrowed from the caller.
    owned: bool,
}

#[derive(Clone, Copy)]
struct VarRef {
    loc: Loc,
    is_ref: bool,
    owned: bool,
}

struct Loop {
    next: Label,
    end: Label,
    /// `continue` / `break` release the variables of the scopes from this index on.
    continue_from: usize,
    break_from: usize,
}

#[derive(Clone)]
struct ParamInfo {
    name: String,
    ty: Type,
    key: VarKey,
    span: Span,
}

struct FnItem<'a> {
    body: &'a Block,
    fallible: bool,
    /// Where to report a problem with the return type.
    span: Span,
    params: Vec<ParamInfo>,
    ret: Type,
    /// For a lambda: the variables it takes from the functions around it.
    captures: Vec<(String, Type)>,
}

/// Every lambda of a block, those nested in other lambdas included.
fn lambdas_in<'a>(block: &'a Block, out: &mut Vec<&'a Expr>) {
    fn stmt<'a>(s: &'a Stmt, out: &mut Vec<&'a Expr>) {
        match &s.kind {
            StmtKind::Let { init: e, .. } | StmtKind::Expr(e) | StmtKind::Fail(e) | StmtKind::Return(Some(e)) => expr(e, out),
            StmtKind::Return(None) | StmtKind::Break | StmtKind::Continue => {}
            StmtKind::Assign { target, value, .. } => {
                expr(target, out);
                expr(value, out);
            }
            StmtKind::If { cond, then, els } => {
                expr(cond, out);
                lambdas_in(then, out);
                if let Some(other) = els {
                    stmt(other, out);
                }
            }
            StmtKind::While { cond: e, body } | StmtKind::For { iter: e, body, .. } => {
                expr(e, out);
                lambdas_in(body, out);
            }
            StmtKind::Fork(body) | StmtKind::Block(body) => lambdas_in(body, out),
            StmtKind::Send { chan, value } => {
                expr(chan, out);
                expr(value, out);
            }
        }
    }
    fn expr<'a>(e: &'a Expr, out: &mut Vec<&'a Expr>) {
        match &e.kind {
            ExprKind::Int(_) | ExprKind::Float(_) | ExprKind::Bool(_) | ExprKind::Ident(_) => {}
            ExprKind::Lambda { body, .. } => {
                out.push(e);
                lambdas_in(body, out);
            }
            ExprKind::Str(parts) => {
                for part in parts {
                    if let StrPart::Expr(inner) = part {
                        expr(inner, out);
                    }
                }
            }
            ExprKind::List(items) => items.iter().for_each(|item| expr(item, out)),
            ExprKind::Map(entries) => {
                for (key, value) in entries {
                    expr(key, out);
                    expr(value, out);
                }
            }
            ExprKind::StructLit { fields, .. } => fields.iter().for_each(|f| expr(&f.value, out)),
            ExprKind::Unary { expr: inner, .. } | ExprKind::Try(inner) | ExprKind::Recv(inner) => expr(inner, out),
            ExprKind::Field { obj, .. } => expr(obj, out),
            ExprKind::Binary { lhs, rhs, .. } => {
                expr(lhs, out);
                expr(rhs, out);
            }
            ExprKind::Index { obj, index } => {
                expr(obj, out);
                expr(index, out);
            }
            ExprKind::Range { lo, hi } => {
                expr(lo, out);
                expr(hi, out);
            }
            ExprKind::Call { callee, args } => {
                expr(callee, out);
                args.iter().for_each(|arg| expr(arg, out));
            }
            ExprKind::Or { expr: inner, default } => {
                expr(inner, out);
                expr(default, out);
            }
            ExprKind::Catch { expr: inner, body, .. } => {
                expr(inner, out);
                lambdas_in(body, out);
            }
            ExprKind::ChanNew { cap, .. } => {
                if let Some(cap) = cap {
                    expr(cap, out);
                }
            }
        }
    }
    for s in &block.stmts {
        stmt(s, out);
    }
}

/// An argument of a call to the runtime.
enum Arg<'e> {
    /// A reference the runtime only looks at.
    Borrow(&'e Expr),
    /// A reference whose ownership passes to the runtime (stored in a list...).
    Move(&'e Expr),
    /// An integer or a boolean.
    Value(&'e Expr),
    Const(i64),
    Descriptor(Type),
}

/// Where the value of a `call() catch err { ... }` goes.
enum Sink {
    /// Into a variable that is being declared.
    Var(Loc),
    /// Into an existing variable.
    Assign(VarRef),
    /// Out of the function.
    Return,
    /// Nowhere: the expression is a statement.
    Discard,
}

/// A piece of a string being assembled.
enum Piece<'e> {
    Text(String),
    Expr(&'e Expr),
}

struct Gen<'a> {
    an: &'a Analysis,
    asm: Asm,
    diags: Vec<Diagnostic>,
    /// Every function and method of the program, by name (or method key).
    items: HashMap<String, FnItem<'a>>,
    labels: HashMap<String, Label>,
    /// Functions that are referred to, and those among them still to compile.
    requested: HashSet<String>,
    queue: Vec<String>,
    /// Top-level variable -> (offset from R15, type).
    globals: HashMap<String, (i32, Type)>,
    strings: HashMap<Vec<u8>, Label>,
    /// Type (by its display name) -> its descriptor table.
    descriptors: HashMap<String, Label>,
    pending_descriptors: Vec<(Type, Label)>,
    pending_closures: Vec<(Vec<Type>, Label)>,
    static_closures: HashMap<String, Label>,
    pending_statics: Vec<(String, Label)>,
    /// Number of interface call sites; each has a two-word cache after the globals.
    caches: usize,
    /// Shared pieces of code that report an error and never return.
    div_zero: Option<Label>,
    index_oob: Option<Label>,

    // ---- state of the function being compiled ----
    /// Local variables, innermost scope last.
    scopes: Vec<Vec<Var>>,
    /// The variables that were given a register.
    regs: HashMap<VarKey, Reg>,
    /// Frame slots used so far.
    slots: i32,
    loops: Vec<Loop>,
    epilogue: Option<Label>,
    /// The statement being compiled is the last one of the function body.
    at_tail: bool,
    /// The function being compiled can fail: it reports in RDX whether it did.
    fallible: bool,
    /// The call whose arguments are about to be dropped can fail: RDX matters.
    keep_error: bool,
    /// The runtime function about to be called can fail.
    rt_fallible: bool,
}

impl<'a> Gen<'a> {
    fn unsupported(&mut self, span: Span, what: &str) {
        self.diags.push(
            Diagnostic::new("E0500", format!("{what} are not supported by the native target yet"), span)
                .help("the native target is new and grows step by step; this program still runs with `onyx run`"),
        );
    }

    fn check_type(&mut self, ty: &Type, span: Span) {
        if !supported(ty) {
            self.unsupported(span, &format!("values of type `{ty}`"));
        }
    }

    fn ty(&self, e: &Expr) -> Type {
        self.an.types.get(&e.id).cloned().unwrap_or(Type::Unknown)
    }

    fn call_kind(&self, e: &Expr) -> Option<&CallKind> {
        self.an.calls.get(&e.id)
    }

    // ---- functions, on demand ----

    fn add_function(&mut self, key: String, item: FnItem<'a>) {
        let label = self.asm.new_label();
        self.labels.insert(key.clone(), label);
        self.items.insert(key, item);
    }

    /// The address of a function, which gets compiled if it was not yet.
    fn function_label(&mut self, key: &str) -> Label {
        let label = *self.labels.get(key).unwrap_or_else(|| panic!("unknown function `{key}`"));
        if self.requested.insert(key.to_string()) {
            self.queue.push(key.to_string());
        }
        label
    }

    /// Calls a runtime function whose arguments are already on the stack, and
    /// removes `drop` of them afterwards.
    fn call_runtime(&mut self, name: &str, drop: usize) {
        let label = self.function_label(name);
        self.asm.call(label);
        if drop > 0 {
            self.asm.alu_imm(Alu::Add, RSP, 8 * drop as i32);
        }
    }

    // ---- constants ----

    fn string(&mut self, text: &str) -> Label {
        if let Some(&label) = self.strings.get(text.as_bytes()) {
            return label;
        }
        let label = self.asm.new_label();
        self.strings.insert(text.as_bytes().to_vec(), label);
        label
    }

    /// The descriptor table of a type; it is written out by `emit_descriptors`.
    fn descriptor(&mut self, ty: &Type) -> Label {
        // An error is its message: a string.
        let ty = if *ty == Type::Error { &Type::Str } else { ty };
        let key = ty.to_string();
        if let Some(&label) = self.descriptors.get(&key) {
            return label;
        }
        let label = self.asm.new_label();
        self.descriptors.insert(key, label);
        self.pending_descriptors.push((ty.clone(), label));
        label
    }

    fn emit_descriptors(&mut self) -> bool {
        if self.pending_descriptors.is_empty() && self.pending_closures.is_empty() && self.pending_statics.is_empty() {
            return false;
        }
        while let Some((ty, label)) = self.pending_descriptors.pop() {
            self.asm.align(8);
            match &ty {
                Type::List(elem) => {
                    let elem = self.descriptor(elem);
                    self.asm.bind(label);
                    self.asm.word(4);
                    self.asm.address(elem);
                }
                Type::Map(key, value) => {
                    let (key, value) = (self.descriptor(key), self.descriptor(value));
                    self.asm.bind(label);
                    self.asm.word(7);
                    self.asm.address(key);
                    self.asm.address(value);
                }
                Type::Struct(name) => {
                    let info = self.an.structs[name].clone();
                    let name_label = self.string(name);
                    let mut fields = Vec::new();
                    for (field, field_ty) in &info.fields {
                        fields.push((self.string(field), self.descriptor(field_ty)));
                    }
                    // Any method may be called through an interface, so all of them are kept.
                    let mut names: Vec<&String> = info.methods.keys().collect();
                    names.sort();
                    let mut methods = Vec::new();
                    for method in names {
                        methods.push((self.string(method), self.function_label(&method_key(name, method))));
                    }
                    let table = self.asm.new_label();

                    self.asm.bind(label);
                    self.asm.word(5);
                    self.asm.address(name_label);
                    self.asm.word(fields.len() as u64);
                    self.asm.address(table);
                    for (field_name, field_td) in fields {
                        self.asm.address(field_name);
                        self.asm.address(field_td);
                    }
                    self.asm.bind(table);
                    self.asm.word(methods.len() as u64);
                    for (method_name, code) in methods {
                        self.asm.address(method_name);
                        self.asm.address(code);
                    }
                }
                other => {
                    let kind = match other {
                        Type::Bool => 1,
                        Type::Float => 2,
                        Type::Str => 3,
                        // Like an interface value, a function value says
                        // what it is itself (see `closure_descriptor`).
                        Type::Interface(_) | Type::Fn(_) => 6,
                        _ => 0,
                    };
                    self.asm.bind(label);
                    self.asm.word(kind);
                }
            }
        }
        while let Some((captures, label)) = self.pending_closures.pop() {
            // Laid out like the descriptor of a struct whose first field is
            // the address of the code, so that releasing a closure is
            // releasing a struct. Kind 9 instead of 5 tells them apart.
            let name = self.string("fn");
            let int = self.descriptor(&Type::Int);
            let fields: Vec<Label> = captures.iter().map(|ty| self.descriptor(ty)).collect();
            self.asm.align(8);
            self.asm.bind(label);
            self.asm.word(9);
            self.asm.address(name);
            self.asm.word(1 + fields.len() as u64);
            self.asm.word(0);
            self.asm.address(name);
            self.asm.address(int);
            for td in fields {
                self.asm.address(name);
                self.asm.address(td);
            }
        }
        while let Some((key, label)) = self.pending_statics.pop() {
            // A function that captures nothing: one constant closure, never released.
            let td = self.closure_descriptor(&[]);
            let code = self.function_label(&key);
            self.asm.align(8);
            self.asm.bind(label);
            self.asm.half(-1i32 as u32);
            self.asm.address32(td);
            self.asm.address(code);
        }
        true
    }

    /// The descriptor of closures that capture values of these types.
    fn closure_descriptor(&mut self, captures: &[Type]) -> Label {
        let names: Vec<String> = captures.iter().map(|ty| ty.to_string()).collect();
        let key = format!("closure({})", names.join(", "));
        if let Some(&label) = self.descriptors.get(&key) {
            return label;
        }
        let label = self.asm.new_label();
        self.descriptors.insert(key, label);
        self.pending_closures.push((captures.to_vec(), label));
        label
    }

    /// The closure of a function (or lambda) that captures nothing.
    fn static_closure(&mut self, key: &str) -> Label {
        if let Some(&label) = self.static_closures.get(key) {
            return label;
        }
        let label = self.asm.new_label();
        self.static_closures.insert(key.to_string(), label);
        self.pending_statics.push((key.to_string(), label));
        label
    }

    /// String constants: a header marking them as never released, then the text.
    fn emit_strings(&mut self) {
        let string_td = self.descriptor(&Type::Str);
        let mut strings: Vec<(Vec<u8>, Label)> = self.strings.iter().map(|(s, l)| (s.clone(), *l)).collect();
        strings.sort_by(|a, b| a.0.cmp(&b.0));
        for (text, label) in strings {
            self.asm.align(8);
            self.asm.bind(label);
            self.asm.half(-1i32 as u32);
            self.asm.address32(string_td);
            self.asm.half(text.len() as u32);
            self.asm.half(text.len() as u32);
            self.asm.bytes(&text);
        }
    }

    /// The shared error paths, written once and jumped to from everywhere.
    fn emit_stubs(&mut self) -> bool {
        let mut emitted = false;
        if let Some(label) = self.div_zero.filter(|l| !self.asm.is_bound(*l)) {
            self.asm.bind(label);
            let message = self.string("division by zero");
            self.asm.lea(RAX, message);
            self.asm.push(RAX);
            self.call_runtime("__rt_panic", 0);
            emitted = true;
        }
        if let Some(label) = self.index_oob.filter(|l| !self.asm.is_bound(*l)) {
            // Reached with the list in RCX and the index in RAX.
            self.asm.bind(label);
            self.asm.push(RCX);
            self.asm.push(RAX);
            self.call_runtime("__rt_index_panic", 0);
            emitted = true;
        }
        emitted
    }

    fn div_zero_label(&mut self) -> Label {
        if self.div_zero.is_none() {
            self.div_zero = Some(self.asm.new_label());
        }
        self.div_zero.unwrap()
    }

    fn index_oob_label(&mut self) -> Label {
        if self.index_oob.is_none() {
            self.index_oob = Some(self.asm.new_label());
        }
        self.index_oob.unwrap()
    }

    // ---- variables ----

    fn lookup(&self, name: &str) -> Option<VarRef> {
        for scope in self.scopes.iter().rev() {
            if let Some(v) = scope.iter().rev().find(|v| v.name == name) {
                return Some(VarRef { loc: v.loc, is_ref: v.is_ref, owned: v.owned });
            }
        }
        self.globals.get(name).map(|(offset, ty)| VarRef { loc: Loc::Global(*offset), is_ref: is_ref(ty), owned: true })
    }

    /// The variable `e` names, if it is a local one (a parameter included).
    fn local(&self, e: &Expr) -> Option<VarRef> {
        let ExprKind::Ident(name) = &e.kind else { return None };
        self.lookup(name).filter(|v| !matches!(v.loc, Loc::Global(_)))
    }

    /// The home of a variable: the register it was planned in, or a new frame slot.
    fn home(&mut self, key: VarKey) -> Loc {
        match self.regs.get(&key) {
            Some(&r) => Loc::Reg(r),
            None => {
                self.slots += 1;
                Loc::Frame(-8 * self.slots)
            }
        }
    }

    fn declare(&mut self, name: &str, key: VarKey, ty: &Type) -> Loc {
        let loc = self.home(key);
        let reference = is_ref(ty);
        self.scopes.last_mut().unwrap().push(Var { name: name.to_string(), loc, is_ref: reference, owned: reference });
        loc
    }

    fn load_loc(&mut self, dst: Reg, loc: Loc) {
        match loc {
            Loc::Reg(r) => self.asm.mov(dst, r),
            Loc::Frame(offset) => self.asm.load(dst, RBP, offset),
            Loc::Global(offset) => self.asm.load(dst, R15, offset),
        }
    }

    fn store_loc(&mut self, loc: Loc, src: Reg) {
        match loc {
            Loc::Reg(r) => self.asm.mov(r, src),
            Loc::Frame(offset) => self.asm.store(RBP, offset, src),
            Loc::Global(offset) => self.asm.store(R15, offset, src),
        }
    }

    fn load_operand(&mut self, dst: Reg, operand: Operand) {
        match operand {
            Operand::Imm(v) => self.asm.mov_imm(dst, v),
            Operand::At(loc) => self.load_loc(dst, loc),
        }
    }

    /// `dst = dst op operand`
    fn operand_alu(&mut self, op: Alu, dst: Reg, operand: Operand) {
        match operand {
            Operand::Imm(v) => self.asm.alu_imm(op, dst, v as i32),
            Operand::At(Loc::Reg(r)) => self.asm.alu(op, dst, r),
            Operand::At(Loc::Frame(offset)) => self.asm.alu_load(op, dst, RBP, offset),
            Operand::At(Loc::Global(offset)) => self.asm.alu_load(op, dst, R15, offset),
        }
    }

    /// If `e` is an integer or boolean that needs no computation: a small
    /// constant or a variable.
    fn simple(&self, e: &Expr) -> Option<Operand> {
        match &e.kind {
            ExprKind::Int(n) if i32::try_from(*n).is_ok() => Some(Operand::Imm(*n)),
            ExprKind::Bool(b) => Some(Operand::Imm(*b as i64)),
            ExprKind::Ident(name) => self.lookup(name).filter(|v| !v.is_ref).map(|v| Operand::At(v.loc)),
            ExprKind::Call { args, .. } => match self.call_kind(e) {
                // The runtime's state has a register of its own.
                Some(CallKind::Builtin(name)) if name == "__state" => Some(Operand::At(Loc::Reg(R15))),
                // The address of a string held by a local variable is that variable.
                Some(CallKind::Builtin(name)) if name == "__str_ptr" => self.local(&args[0]).map(|v| Operand::At(v.loc)),
                _ => None,
            },
            _ => None,
        }
    }

    /// Evaluates `e`, an integer or a boolean, straight into a variable.
    fn expr_into(&mut self, e: &Expr, loc: Loc) {
        match (loc, self.simple(e)) {
            (Loc::Reg(r), Some(operand)) => self.load_operand(r, operand),
            (Loc::Frame(offset), Some(Operand::Imm(v))) => self.asm.store_imm(RBP, offset, v as i32),
            (Loc::Global(offset), Some(Operand::Imm(v))) => self.asm.store_imm(R15, offset, v as i32),
            _ => {
                self.expr(e);
                self.store_loc(loc, RAX);
            }
        }
    }

    /// Pushes `e`, an integer or a boolean.
    fn push_value(&mut self, e: &Expr) {
        match self.simple(e) {
            Some(Operand::Imm(v)) => self.asm.push_imm(v as i32),
            Some(Operand::At(Loc::Reg(r))) => self.asm.push(r),
            Some(Operand::At(Loc::Frame(offset))) => self.asm.push_mem(RBP, offset),
            Some(Operand::At(Loc::Global(offset))) => self.asm.push_mem(R15, offset),
            None => {
                self.expr(e);
                self.asm.push(RAX);
            }
        }
    }

    // ---- reference counting ----

    /// Adds one reference to the object whose address is in `r`. Changes no register.
    fn retain(&mut self, r: Reg) {
        self.asm.cmp32_mem(r, COUNT, 0);
        let constant = self.asm.jcc_short(Cc::L); // constants are never counted
        self.asm.inc32_mem(r, COUNT);
        self.asm.bind_short(constant);
    }

    /// Drops one reference to the object in RAX, destroying it if it was the
    /// last. Every scratch register may change.
    fn release_rax(&mut self) {
        self.asm.cmp32_mem(RAX, COUNT, 1);
        let constant = self.asm.jcc_short(Cc::L);
        let last = self.asm.jcc_short(Cc::E);
        self.asm.dec32_mem(RAX, COUNT);
        let done = self.asm.jmp_short();
        self.asm.bind_short(last);
        self.asm.push(RAX);
        self.call_runtime("__rt_destroy", 1);
        self.asm.bind_short(done);
        self.asm.bind_short(constant);
    }

    /// With a result in RAX and an owned reference on top of the stack:
    /// releases that reference and keeps the result.
    fn release_saved(&mut self) {
        self.asm.pop(RCX);
        self.asm.push(RAX);
        self.asm.mov(RAX, RCX);
        self.release_rax();
        self.asm.pop(RAX);
    }

    fn owned_refs(&self, first: usize, except: Option<Loc>) -> Vec<Loc> {
        self.scopes[first..]
            .iter()
            .rev()
            .flat_map(|scope| scope.iter().rev())
            .filter(|v| v.is_ref && v.owned && Some(v.loc) != except)
            .map(|v| v.loc)
            .collect()
    }

    /// Releases the variables of the scopes from `first` on (they stay declared).
    fn release_scopes(&mut self, first: usize) {
        for loc in self.owned_refs(first, None) {
            self.load_loc(RAX, loc);
            self.release_rax();
        }
    }

    /// After a call: releases the arguments that were temporary values
    /// (`owned[i]` for the i-th pushed argument) and removes them all from the
    /// stack. The result in RAX is preserved when `keep_result` is set, and
    /// so is the error in RDX after a call that can fail (`keep_error`).
    fn drop_args(&mut self, owned: &[bool], keep_result: bool) {
        let keep_error = std::mem::take(&mut self.keep_error);
        let n = owned.len() as i32;
        if n == 0 {
            return;
        }
        if owned.iter().any(|&o| o) {
            let mut base = 0;
            if keep_result {
                self.asm.push(RAX);
                base += 8;
            }
            if keep_error {
                self.asm.push(RDX);
                base += 8;
            }
            for (i, _) in owned.iter().enumerate().filter(|(_, &o)| o) {
                self.asm.load(RAX, RSP, base + 8 * (n - 1 - i as i32));
                self.release_rax();
            }
            if keep_error {
                self.asm.pop(RDX);
            }
            if keep_result {
                self.asm.pop(RAX);
            }
        }
        self.asm.alu_imm(Alu::Add, RSP, 8 * n);
    }

    // ---- functions ----

    fn function(&mut self, key: &str) {
        let (body, fallible, span, params, ret, captures) = {
            let item = &self.items[key];
            (item.body, item.fallible, item.span, item.params.clone(), item.ret.clone(), item.captures.clone())
        };
        for p in &params {
            self.check_type(&p.ty, p.span);
        }
        self.check_type(&ret, span);
        self.fallible = fallible;

        let names: Vec<(String, VarKey)> = params.iter().map(|p| (p.name.clone(), p.key)).collect();
        let plan = plan::plan(body, &names, &VARIABLE_REGS);
        let mut saved: Vec<Reg> = plan.regs.values().copied().collect();
        saved.sort();
        self.regs = plan.regs;
        self.slots = saved.len() as i32;
        self.loops.clear();
        let epilogue = self.asm.new_label();
        self.epilogue = Some(epilogue);

        let label = self.labels[key];
        self.asm.bind(label);
        self.asm.push(RBP);
        self.asm.mov(RBP, RSP);
        let frame_size_at = self.asm.alu_imm32_patchable(Alu::Sub, RSP, 0);
        for (k, &r) in saved.iter().enumerate() {
            self.asm.store(RBP, -8 * (k as i32 + 1), r);
        }

        // The first argument was pushed first, so it is the farthest from RBP.
        let count = params.len() as i32;
        let mut scope = Vec::new();
        // A lambda finds its closure in R10. What it captured is copied out
        // of it; the closure, which the caller holds, keeps all of it alive.
        for (i, (name, ty)) in captures.iter().enumerate() {
            self.slots += 1;
            let slot = -8 * self.slots;
            self.asm.load(RAX, R10, FIELDS + 8 + 8 * i as i32);
            self.asm.store(RBP, slot, RAX);
            scope.push(Var { name: name.clone(), loc: Loc::Frame(slot), is_ref: is_ref(ty), owned: false });
        }
        for (i, p) in params.iter().enumerate() {
            let pushed_at = 16 + 8 * (count - 1 - i as i32);
            // A parameter is borrowed from the caller, unless the function
            // assigns to it: then it needs a reference of its own.
            let reference = is_ref(&p.ty);
            let owned = reference && plan.assigned.contains(&p.key);
            let loc = match self.regs.get(&p.key) {
                Some(&r) => {
                    self.asm.load(r, RBP, pushed_at);
                    Loc::Reg(r)
                }
                // It also needs a place of its own: after the call, the
                // caller looks at what it pushed to release temporary values.
                None if owned => {
                    self.slots += 1;
                    let slot = -8 * self.slots;
                    self.asm.load(RAX, RBP, pushed_at);
                    self.asm.store(RBP, slot, RAX);
                    Loc::Frame(slot)
                }
                None => Loc::Frame(pushed_at),
            };
            if owned {
                self.load_loc(RAX, loc);
                self.retain(RAX);
            }
            scope.push(Var { name: p.name.clone(), loc, is_ref: reference, owned });
        }
        self.scopes = vec![scope];

        let last = body.stmts.len().wrapping_sub(1);
        for (i, stmt) in body.stmts.iter().enumerate() {
            self.at_tail = i == last;
            self.stmt(stmt);
        }
        self.at_tail = false;
        if !leaves(body) {
            self.release_scopes(0);
        }
        if fallible {
            self.asm.mov_imm(RDX, 0); // reaching the end means success
        }

        self.asm.bind(epilogue);
        for (k, &r) in saved.iter().enumerate() {
            self.asm.load(r, RBP, -8 * (k as i32 + 1));
        }
        self.asm.mov(RSP, RBP);
        self.asm.pop(RBP);
        self.asm.ret();
        self.asm.patch32(frame_size_at, self.slots * 8);
        self.scopes.clear();
        self.regs.clear();
    }

    // ---- statements ----

    fn block(&mut self, block: &Block) {
        self.scopes.push(Vec::new());
        for stmt in &block.stmts {
            self.stmt(stmt);
        }
        if !leaves(block) {
            self.release_scopes(self.scopes.len() - 1);
        }
        self.scopes.pop();
    }

    fn stmt(&mut self, stmt: &Stmt) {
        let tail = std::mem::replace(&mut self.at_tail, false);
        match &stmt.kind {
            StmtKind::Let { name, name_span, init, .. } if matches!(init.kind, ExprKind::Catch { .. }) => {
                // The variable only exists once one of the two paths gave it a value.
                let ty = self.ty(init);
                let loc = self.home((name_span.start, NAMED));
                self.catch(init, Sink::Var(loc));
                let reference = is_ref(&ty);
                self.scopes.last_mut().unwrap().push(Var { name: name.clone(), loc, is_ref: reference, owned: reference });
            }
            StmtKind::Let { name, name_span, init, .. } => {
                let ty = self.ty(init);
                if is_ref(&ty) {
                    self.expr(init);
                    let loc = self.declare(name, (name_span.start, NAMED), &ty);
                    self.store_loc(loc, RAX);
                } else {
                    // The value is computed before the name exists: it may
                    // mention an outer variable of the same name.
                    let loc = self.home((name_span.start, NAMED));
                    self.expr_into(init, loc);
                    self.scopes.last_mut().unwrap().push(Var { name: name.clone(), loc, is_ref: false, owned: false });
                }
            }
            StmtKind::Assign { target, value, .. } if matches!(value.kind, ExprKind::Catch { .. }) => {
                // After lowering, the target of such an assignment is a plain variable.
                match &target.kind {
                    ExprKind::Ident(name) => match self.lookup(name) {
                        Some(var) => self.catch(value, Sink::Assign(var)),
                        None => self.unsupported(target.span, "assignments to this name"),
                    },
                    _ => self.unsupported(target.span, "this use of `catch`"),
                }
            }
            StmtKind::Assign { target, op, value } => self.assign(target, *op, value),
            StmtKind::Expr(e) if matches!(e.kind, ExprKind::Catch { .. }) => self.catch(e, Sink::Discard),
            StmtKind::Expr(e) => {
                self.expr(e);
                if is_ref(&self.ty(e)) {
                    self.release_rax();
                }
            }
            StmtKind::If { cond, then, els } => {
                let otherwise = self.asm.new_label();
                self.cond_jump(cond, otherwise, false);
                self.block(then);
                match els {
                    Some(els) => {
                        let end = self.asm.new_label();
                        if !leaves(then) {
                            self.asm.jmp(end);
                        }
                        self.asm.bind(otherwise);
                        self.stmt(els);
                        self.asm.bind(end);
                    }
                    None => self.asm.bind(otherwise),
                }
            }
            StmtKind::While { cond, body } => {
                // The test sits at the bottom: one jump per turn instead of two.
                let (top, check, end) = (self.asm.new_label(), self.asm.new_label(), self.asm.new_label());
                let forever = matches!(cond.kind, ExprKind::Bool(true));
                if !forever {
                    self.asm.jmp(check);
                }
                self.asm.bind(top);
                let depth = self.scopes.len();
                self.loops.push(Loop { next: check, end, continue_from: depth, break_from: depth });
                self.block(body);
                self.loops.pop();
                self.asm.bind(check);
                if forever {
                    self.asm.jmp(top);
                } else {
                    self.cond_jump(cond, top, true);
                }
                self.asm.bind(end);
            }
            StmtKind::For { var, var_span, iter, body } => match self.ty(iter) {
                Type::Range => self.for_range(var, *var_span, iter, body),
                Type::List(elem) => self.for_list(var, *var_span, iter, body, &elem),
                Type::Map(key, _) => self.for_map(var, *var_span, iter, body, &key),
                Type::Str => self.for_str(var, *var_span, iter, body),
                _ => self.unsupported(iter.span, "loops over channels"),
            },
            StmtKind::Return(Some(v)) if matches!(v.kind, ExprKind::Catch { .. }) => self.catch(v, Sink::Return),
            StmtKind::Return(value) => {
                // Returning an owned local variable hands its reference over
                // to the caller instead of making a new one and dropping the old.
                let mut moved = None;
                if let Some(v) = value {
                    match self.local(v) {
                        Some(var) if var.is_ref && var.owned => {
                            self.load_loc(RAX, var.loc);
                            moved = Some(var.loc);
                        }
                        _ => self.expr(v),
                    }
                }
                self.finish_return(value.is_some(), moved, tail);
            }
            StmtKind::Fail(value) => {
                // The error (a string) goes to the caller in RDX.
                let mut moved = None;
                match self.local(value) {
                    Some(var) if var.is_ref && var.owned => {
                        self.load_loc(RAX, var.loc);
                        moved = Some(var.loc);
                    }
                    _ => self.expr(value),
                }
                self.leave_with_error(RAX, moved);
            }
            StmtKind::Break => {
                let (from, end) = self.loops.last().map(|l| (l.break_from, l.end)).unwrap();
                self.release_scopes(from);
                self.asm.jmp(end);
            }
            StmtKind::Continue => {
                let (from, next) = self.loops.last().map(|l| (l.continue_from, l.next)).unwrap();
                self.release_scopes(from);
                self.asm.jmp(next);
            }
            StmtKind::Block(body) => self.block(body),
            StmtKind::Fork(_) => self.unsupported(stmt.span, "`fork` blocks"),
            StmtKind::Send { .. } => self.unsupported(stmt.span, "channels"),
        }
    }

    /// Ends the function normally. The returned value, if any, is in RAX;
    /// `moved` is the variable it was taken from (and that must not be released).
    fn finish_return(&mut self, has_value: bool, moved: Option<Loc>, tail: bool) {
        let pending = self.owned_refs(0, moved);
        if !pending.is_empty() {
            if has_value {
                self.asm.push(RAX);
            }
            for loc in pending {
                self.load_loc(RAX, loc);
                self.release_rax();
            }
            if has_value {
                self.asm.pop(RAX);
            }
        }
        // The last statement of a function simply reaches its end.
        if !tail {
            if self.fallible {
                self.asm.mov_imm(RDX, 0);
            }
            let epilogue = self.epilogue.unwrap();
            self.asm.jmp(epilogue);
        }
    }

    /// Ends the function with the error held in `error` (RAX or RDX).
    fn leave_with_error(&mut self, error: Reg, moved: Option<Loc>) {
        let pending = self.owned_refs(0, moved);
        if !pending.is_empty() {
            self.asm.push(error);
            for loc in pending {
                self.load_loc(RAX, loc);
                self.release_rax();
            }
            self.asm.pop(RDX);
        } else {
            self.asm.mov(RDX, error);
        }
        let epilogue = self.epilogue.unwrap();
        self.asm.jmp(epilogue);
    }

    /// `call() catch err { ... }`: the call's value goes to `sink`; if the
    /// call fails, the block runs with the error, and may provide a value
    /// instead (its last expression) or leave.
    fn catch(&mut self, e: &Expr, sink: Sink) {
        let ExprKind::Catch { expr: call, name, name_span, body } = &e.kind else { return };
        let ty = self.ty(e);
        let has_value = self.an.catch_values.contains(&e.id);
        let (handler, done) = (self.asm.new_label(), self.asm.new_label());
        self.expr(call);
        self.asm.test(RDX, RDX);
        self.asm.jcc(Cc::Ne, handler);
        self.sink(&sink, &ty);
        if !matches!(sink, Sink::Return) {
            self.asm.jmp(done);
        }

        self.asm.bind(handler);
        self.scopes.push(Vec::new());
        let error = self.declare(name, (name_span.start, NAMED), &Type::Error);
        self.store_loc(error, RDX);
        let scope = self.scopes.len() - 1;
        let (value, rest) = match body.stmts.split_last() {
            Some((Stmt { kind: StmtKind::Expr(last), .. }, rest)) if has_value => (Some(last), rest),
            _ => (None, &body.stmts[..]),
        };
        for stmt in rest {
            self.stmt(stmt);
        }
        match value {
            Some(value) => {
                // The block's last expression stands in for the call's value.
                self.expr(value);
                self.asm.push(RAX);
                self.release_scopes(scope);
                self.asm.pop(RAX);
                self.scopes.pop();
                self.sink(&sink, &ty);
            }
            None => {
                if !leaves(body) {
                    self.release_scopes(scope);
                }
                self.scopes.pop();
                // `return call() catch err { ... }` with nothing to return.
                if matches!(sink, Sink::Return) && !leaves(body) {
                    self.finish_return(false, None, false);
                }
            }
        }
        self.asm.bind(done);
    }

    /// Sends the value in RAX where a `catch` expression's value goes.
    fn sink(&mut self, sink: &Sink, ty: &Type) {
        match sink {
            Sink::Var(loc) => self.store_loc(*loc, RAX),
            Sink::Assign(var) => {
                if var.is_ref {
                    self.load_loc(RCX, var.loc);
                    self.store_loc(var.loc, RAX);
                    self.asm.mov(RAX, RCX);
                    self.release_rax();
                } else {
                    self.store_loc(var.loc, RAX);
                }
            }
            Sink::Return => self.finish_return(*ty != Type::Void, None, false),
            Sink::Discard => {
                if is_ref(ty) {
                    self.release_rax();
                }
            }
        }
    }

    fn for_range(&mut self, var: &str, var_span: Span, iter: &Expr, body: &Block) {
        let ExprKind::Range { lo, hi } = &iter.kind else {
            self.unsupported(iter.span, "ranges stored in variables");
            return;
        };
        let (top, next, check, end) =
            (self.asm.new_label(), self.asm.new_label(), self.asm.new_label(), self.asm.new_label());
        self.scopes.push(Vec::new());
        // Both bounds are computed once, before the loop variable exists.
        let counter = self.home((var_span.start, NAMED));
        self.expr_into(lo, counter);
        let limit = match self.simple(hi) {
            Some(Operand::Imm(v)) => Operand::Imm(v),
            _ => {
                let loc = self.home((var_span.start, COUNTER));
                self.expr_into(hi, loc);
                Operand::At(loc)
            }
        };
        self.scopes.last_mut().unwrap().push(Var { name: var.to_string(), loc: counter, is_ref: false, owned: false });

        self.asm.jmp(check);
        self.asm.bind(top);
        let depth = self.scopes.len();
        self.loops.push(Loop { next, end, continue_from: depth, break_from: depth });
        self.block(body);
        self.loops.pop();
        self.asm.bind(next);
        match counter {
            Loc::Reg(r) => self.asm.alu_imm(Alu::Add, r, 1),
            Loc::Frame(offset) => self.asm.alu_store_imm(Alu::Add, RBP, offset, 1),
            Loc::Global(offset) => self.asm.alu_store_imm(Alu::Add, R15, offset, 1),
        }
        self.asm.bind(check);
        match counter {
            Loc::Reg(r) => self.operand_alu(Alu::Cmp, r, limit),
            _ => {
                self.load_loc(RAX, counter);
                self.operand_alu(Alu::Cmp, RAX, limit);
            }
        }
        self.asm.jcc(Cc::L, top);
        self.asm.bind(end);
        self.scopes.pop();
    }

    fn for_list(&mut self, var: &str, var_span: Span, iter: &Expr, body: &Block, elem: &Type) {
        let (top, next, check, end) =
            (self.asm.new_label(), self.asm.new_label(), self.asm.new_label(), self.asm.new_label());
        // Outer scope: the list (kept alive for the whole loop) and the position in it.
        self.scopes.push(Vec::new());
        self.expr(iter);
        let list = self.declare("<list>", (var_span.start, SUBJECT), &self.ty(iter));
        self.store_loc(list, RAX);
        let index = self.home((var_span.start, COUNTER));
        match index {
            Loc::Reg(r) => self.asm.mov_imm(r, 0),
            Loc::Frame(offset) => self.asm.store_imm(RBP, offset, 0),
            Loc::Global(offset) => self.asm.store_imm(R15, offset, 0),
        }
        self.asm.jmp(check);

        self.asm.bind(top);
        // Inner scope: the loop variable, released after each turn.
        self.scopes.push(Vec::new());
        self.load_loc(RCX, list);
        self.asm.load(RCX, RCX, LIST_DATA);
        self.load_loc(RAX, index);
        self.asm.load_indexed(RAX, RCX, RAX);
        if is_ref(elem) {
            self.retain(RAX);
        }
        let item = self.declare(var, (var_span.start, NAMED), elem);
        self.store_loc(item, RAX);

        let depth = self.scopes.len();
        self.loops.push(Loop { next, end, continue_from: depth, break_from: depth - 1 });
        self.block(body);
        self.loops.pop();

        self.asm.bind(next);
        self.release_scopes(depth - 1);
        self.scopes.pop();
        match index {
            Loc::Reg(r) => self.asm.alu_imm(Alu::Add, r, 1),
            Loc::Frame(offset) => self.asm.alu_store_imm(Alu::Add, RBP, offset, 1),
            Loc::Global(offset) => self.asm.alu_store_imm(Alu::Add, R15, offset, 1),
        }
        // The length is read again on every turn, so the body may change the list.
        self.asm.bind(check);
        self.load_loc(RCX, list);
        match index {
            Loc::Reg(r) => self.asm.alu_load(Alu::Cmp, r, RCX, LIST_LEN),
            _ => {
                self.load_loc(RAX, index);
                self.asm.alu_load(Alu::Cmp, RAX, RCX, LIST_LEN);
            }
        }
        self.asm.jcc(Cc::L, top);

        self.asm.bind(end);
        self.release_scopes(self.scopes.len() - 1);
        self.scopes.pop();
    }

    /// Jumps to `target` when `cond` is `when`; falls through otherwise.
    fn cond_jump(&mut self, cond: &Expr, target: Label, when: bool) {
        match &cond.kind {
            ExprKind::Bool(b) => {
                if *b == when {
                    self.asm.jmp(target);
                }
            }
            ExprKind::Unary { op: UnOp::Not, expr } => self.cond_jump(expr, target, !when),
            ExprKind::Binary { op: BinOp::And, lhs, rhs } => {
                if when {
                    let skip = self.asm.new_label();
                    self.cond_jump(lhs, skip, false);
                    self.cond_jump(rhs, target, true);
                    self.asm.bind(skip);
                } else {
                    self.cond_jump(lhs, target, false);
                    self.cond_jump(rhs, target, false);
                }
            }
            ExprKind::Binary { op: BinOp::Or, lhs, rhs } => {
                if when {
                    self.cond_jump(lhs, target, true);
                    self.cond_jump(rhs, target, true);
                } else {
                    let skip = self.asm.new_label();
                    self.cond_jump(lhs, skip, true);
                    self.cond_jump(rhs, target, false);
                    self.asm.bind(skip);
                }
            }
            ExprKind::Binary { op: BinOp::Eq | BinOp::NotEq | BinOp::Lt | BinOp::Le | BinOp::Gt | BinOp::Ge, lhs, rhs }
                if matches!(self.ty(lhs), Type::Int | Type::Bool) && matches!(self.ty(rhs), Type::Int | Type::Bool) =>
            {
                let ExprKind::Binary { op, .. } = &cond.kind else { unreachable!() };
                let cc = self.compare(*op, lhs, rhs);
                self.asm.jcc(if when { cc } else { cc.negate() }, target);
            }
            ExprKind::Binary { op: op @ (BinOp::Eq | BinOp::NotEq | BinOp::Lt | BinOp::Le | BinOp::Gt | BinOp::Ge), lhs, rhs }
                if self.ty(lhs) == Type::Float =>
            {
                match (self.float_compare(*op, lhs, rhs), when) {
                    // "Equal" needs both to be numbers; "different" is everything else.
                    (Cc::E, true) | (Cc::Ne, false) => {
                        let unordered = self.asm.jcc_short(Cc::P);
                        self.asm.jcc(Cc::E, target);
                        self.asm.bind_short(unordered);
                    }
                    (Cc::E, false) | (Cc::Ne, true) => {
                        self.asm.jcc(Cc::Ne, target);
                        self.asm.jcc(Cc::P, target);
                    }
                    (cc, true) => self.asm.jcc(cc, target),
                    (cc, false) => self.asm.jcc(cc.negate(), target),
                }
            }
            _ => {
                match self.simple(cond) {
                    Some(Operand::At(Loc::Reg(r))) => self.asm.test(r, r),
                    _ => {
                        self.expr(cond);
                        self.asm.test(RAX, RAX);
                    }
                }
                self.asm.jcc(if when { Cc::Ne } else { Cc::E }, target);
            }
        }
    }

    /// Compares two integers (or booleans) and returns the condition under
    /// which `lhs op rhs` holds.
    fn compare(&mut self, op: BinOp, lhs: &Expr, rhs: &Expr) -> Cc {
        let cc = cc_of(op);
        match (self.simple(lhs), self.simple(rhs)) {
            (Some(Operand::At(Loc::Reg(r))), Some(right)) => {
                self.operand_alu(Alu::Cmp, r, right);
                cc
            }
            (_, Some(right)) => {
                self.expr(lhs);
                self.operand_alu(Alu::Cmp, RAX, right);
                cc
            }
            // The left side is a constant or a local variable: computing the
            // right side first cannot change it.
            (Some(left), None) if !matches!(left, Operand::At(Loc::Global(_))) => {
                self.expr(rhs);
                self.operand_alu(Alu::Cmp, RAX, left);
                cc.swap()
            }
            _ => {
                self.expr(lhs);
                self.asm.push(RAX);
                self.expr(rhs);
                self.asm.mov(RCX, RAX);
                self.asm.pop(RAX);
                self.asm.alu(Alu::Cmp, RAX, RCX);
                cc
            }
        }
    }

    // ---- assignments ----

    fn assign(&mut self, target: &Expr, op: AssignOp, value: &Expr) {
        let ty = self.ty(target);
        let bin = match op {
            AssignOp::Set => None,
            AssignOp::Add => Some(BinOp::Add),
            AssignOp::Sub => Some(BinOp::Sub),
            AssignOp::Mul => Some(BinOp::Mul),
            AssignOp::Div => Some(BinOp::Div),
        };
        match &target.kind {
            ExprKind::Ident(name) => match self.lookup(name) {
                Some(var) => self.assign_variable(target, name, var, &ty, bin, value),
                None => self.unsupported(target.span, "assignments to this name"),
            },
            ExprKind::Field { obj, name, .. } => match self.field_offset(obj, name) {
                Some(offset) => self.assign_field(obj, offset, &ty, bin, value),
                None => self.unsupported(target.span, "assignments to this kind of field"),
            },
            ExprKind::Index { obj, index } if matches!(self.ty(obj), Type::List(_)) => {
                self.assign_element(obj, index, &ty, bin, value)
            }
            ExprKind::Index { obj, index } if matches!(self.ty(obj), Type::Map(..)) => {
                self.assign_entry(obj, index, &ty, bin, value)
            }
            _ => self.unsupported(target.span, "assignments to this kind of expression"),
        }
    }

    fn assign_variable(&mut self, target: &Expr, name: &str, var: VarRef, ty: &Type, bin: Option<BinOp>, value: &Expr) {
        if !is_ref(ty) {
            match bin {
                None => self.expr_into(value, var.loc),
                // `x += 1` and the like work on the variable where it is.
                Some(op @ (BinOp::Add | BinOp::Sub)) if self.simple(value).is_some() => {
                    let operand = self.simple(value).unwrap();
                    let alu = if op == BinOp::Add { Alu::Add } else { Alu::Sub };
                    let (base, offset) = match var.loc {
                        Loc::Reg(r) => return self.operand_alu(alu, r, operand),
                        Loc::Frame(offset) => (RBP, offset),
                        Loc::Global(offset) => (R15, offset),
                    };
                    match operand {
                        Operand::Imm(v) => self.asm.alu_store_imm(alu, base, offset, v as i32),
                        Operand::At(Loc::Reg(r)) => self.asm.alu_store(alu, base, offset, r),
                        other => {
                            self.load_operand(RAX, other);
                            self.asm.alu_store(alu, base, offset, RAX);
                        }
                    }
                }
                // A local variable cannot change while the value is computed.
                Some(op @ (BinOp::Add | BinOp::Sub)) if !matches!(var.loc, Loc::Global(_)) => {
                    let alu = if op == BinOp::Add { Alu::Add } else { Alu::Sub };
                    self.expr(value);
                    match var.loc {
                        Loc::Reg(r) => self.asm.alu(alu, r, RAX),
                        Loc::Frame(offset) => self.asm.alu_store(alu, RBP, offset, RAX),
                        Loc::Global(offset) => self.asm.alu_store(alu, R15, offset, RAX),
                    }
                }
                Some(op) => {
                    self.arith(op, target, value);
                    self.store_loc(var.loc, RAX);
                }
            }
            return;
        }

        // `s += x` and `s = s + x` on a local string: its reference is given
        // to the runtime, which extends the string in place when it can.
        if *ty == Type::Str && !matches!(var.loc, Loc::Global(_)) {
            let piece = match (bin, &value.kind) {
                (Some(BinOp::Add), _) => Some(value),
                (None, ExprKind::Binary { op: BinOp::Add, lhs, rhs })
                    if matches!(&lhs.kind, ExprKind::Ident(n) if n == name) =>
                {
                    Some(&**rhs)
                }
                _ => None,
            };
            if let Some(piece) = piece {
                match var.loc {
                    Loc::Reg(r) => self.asm.push(r),
                    Loc::Frame(offset) => self.asm.push_mem(RBP, offset),
                    Loc::Global(offset) => self.asm.push_mem(R15, offset),
                }
                let owned = self.operand(piece);
                self.asm.push(RAX);
                self.call_runtime("__rt_append", 0);
                self.store_loc(var.loc, RAX);
                if owned {
                    self.asm.load(RAX, RSP, 0);
                    self.release_rax();
                }
                self.asm.alu_imm(Alu::Add, RSP, 16);
                return;
            }
        }

        // Compute the new value, store it, then let go of the one it replaces.
        match bin {
            Some(op) => self.string_binary(op, target, value),
            None => self.expr(value),
        }
        self.load_loc(RCX, var.loc);
        self.store_loc(var.loc, RAX);
        self.asm.mov(RAX, RCX);
        self.release_rax();
    }

    fn assign_field(&mut self, obj: &Expr, offset: i32, ty: &Type, bin: Option<BinOp>, value: &Expr) {
        let reference = is_ref(ty);
        if !reference {
            if let Some(var) = self.local(obj) {
                // The object is in a variable: write (or update) the field in place.
                let additive = matches!(bin, None | Some(BinOp::Add | BinOp::Sub));
                if let (true, Some(operand)) = (additive, self.simple(value)) {
                    let base = self.object_reg(var.loc, RCX);
                    let source = match operand {
                        Operand::Imm(v) => {
                            match bin {
                                None => self.asm.store_imm(base, offset, v as i32),
                                Some(BinOp::Add) => self.asm.alu_store_imm(Alu::Add, base, offset, v as i32),
                                _ => self.asm.alu_store_imm(Alu::Sub, base, offset, v as i32),
                            }
                            return;
                        }
                        Operand::At(Loc::Reg(r)) => r,
                        other => {
                            self.load_operand(RAX, other);
                            RAX
                        }
                    };
                    match bin {
                        None => self.asm.store(base, offset, source),
                        Some(BinOp::Add) => self.asm.alu_store(Alu::Add, base, offset, source),
                        _ => self.asm.alu_store(Alu::Sub, base, offset, source),
                    }
                    return;
                }
                if bin.is_none() {
                    self.expr(value);
                    let base = self.object_reg(var.loc, RCX);
                    self.asm.store(base, offset, RAX);
                    return;
                }
                // The value runs no code of the program, so it cannot change
                // the field: it can be computed first.
                if self.is_pure(value) {
                    self.expr(value);
                    match bin {
                        Some(BinOp::Add) | Some(BinOp::Sub) => {
                            let alu = if bin == Some(BinOp::Add) { Alu::Add } else { Alu::Sub };
                            let base = self.object_reg(var.loc, RCX);
                            self.asm.alu_store(alu, base, offset, RAX);
                        }
                        Some(op) => {
                            self.asm.mov(RCX, RAX);
                            let base = self.object_reg(var.loc, R8);
                            self.asm.load(RAX, base, offset);
                            self.arith_rcx(op);
                            self.asm.store(base, offset, RAX);
                        }
                        None => unreachable!(),
                    }
                    return;
                }
            }
        }

        // General case: the object waits on the stack.
        let owned = self.operand(obj);
        self.asm.push(RAX);
        match bin {
            Some(op) if *ty == Type::Str => {
                // The current text, kept alive while the new one is built.
                debug_assert!(op == BinOp::Add);
                self.asm.load(RAX, RAX, offset);
                self.retain(RAX);
                self.asm.push(RAX);
                let piece_owned = self.operand(value);
                self.asm.push(RAX);
                self.call_runtime("__rt_concat", 0);
                self.drop_args(&[true, piece_owned], true);
            }
            Some(op) => {
                self.asm.load(RAX, RAX, offset);
                self.asm.push(RAX);
                self.expr(value);
                self.asm.mov(RCX, RAX);
                self.asm.pop(RAX);
                self.arith_rcx(op);
            }
            None => self.expr(value),
        }
        self.asm.load(RCX, RSP, 0);
        if reference {
            self.asm.load(RDX, RCX, offset);
        }
        self.asm.store(RCX, offset, RAX);
        if reference {
            self.asm.mov(RAX, RDX);
            self.release_rax();
        }
        self.asm.pop(RAX);
        if owned {
            self.release_rax();
        }
    }

    /// A register holding the object of a local variable: the variable's own
    /// register, or `scratch` after loading it.
    fn object_reg(&mut self, loc: Loc, scratch: Reg) -> Reg {
        match loc {
            Loc::Reg(r) => r,
            other => {
                self.load_loc(scratch, other);
                scratch
            }
        }
    }

    fn assign_element(&mut self, obj: &Expr, index: &Expr, ty: &Type, bin: Option<BinOp>, value: &Expr) {
        let reference = is_ref(ty);
        if let (false, Some(list), Some(position)) = (reference, self.local(obj), self.simple(index)) {
            // An integer list in a variable, at a simple position.
            match bin {
                None => {
                    self.expr(value);
                    self.asm.mov(RDX, RAX);
                    self.load_loc(RCX, list.loc);
                    self.load_operand(RAX, position);
                    self.element_address();
                    self.asm.store_indexed(RCX, RAX, RDX);
                    return;
                }
                // The value runs no code of the program, so it cannot change
                // the list: it can be computed first.
                Some(op @ (BinOp::Add | BinOp::Sub)) if self.is_pure(value) => {
                    self.expr(value);
                    self.asm.mov(RDX, RAX);
                    self.load_loc(RCX, list.loc);
                    self.load_operand(RAX, position);
                    self.element_address();
                    self.asm.load_indexed(R8, RCX, RAX);
                    self.asm.alu(if op == BinOp::Add { Alu::Add } else { Alu::Sub }, R8, RDX);
                    self.asm.store_indexed(RCX, RAX, R8);
                    return;
                }
                _ => {}
            }
        }

        // General case: the list and the position wait on the stack.
        let owned = self.operand(obj);
        self.asm.push(RAX);
        self.expr(index);
        self.asm.push(RAX);
        match bin {
            Some(op) => {
                self.asm.load(RCX, RSP, 8);
                self.element_address();
                self.asm.load_indexed(RAX, RCX, RAX);
                if *ty == Type::Str {
                    debug_assert!(op == BinOp::Add);
                    self.retain(RAX);
                    self.asm.push(RAX);
                    let piece_owned = self.operand(value);
                    self.asm.push(RAX);
                    self.call_runtime("__rt_concat", 0);
                    self.drop_args(&[true, piece_owned], true);
                } else {
                    self.asm.push(RAX);
                    self.expr(value);
                    self.asm.mov(RCX, RAX);
                    self.asm.pop(RAX);
                    self.arith_rcx(op);
                }
            }
            None => self.expr(value),
        }
        self.asm.mov(RDX, RAX);
        self.asm.pop(RAX);
        self.asm.load(RCX, RSP, 0);
        // Checked again: computing the value may have changed the list.
        self.element_address();
        if reference {
            self.asm.load_indexed(R8, RCX, RAX);
        }
        self.asm.store_indexed(RCX, RAX, RDX);
        if reference {
            self.asm.mov(RAX, R8);
            self.release_rax();
        }
        self.asm.pop(RAX);
        if owned {
            self.release_rax();
        }
    }

    // ---- expressions: values ----

    /// Evaluates `e` into RAX. A reference is owned by whoever asked for it.
    fn expr(&mut self, e: &Expr) {
        let ty = self.ty(e);
        if !supported(&ty) {
            self.unsupported(e.span, &format!("values of type `{ty}`"));
            return;
        }
        match &e.kind {
            ExprKind::Int(n) => self.asm.mov_imm(RAX, *n),
            ExprKind::Float(x) => self.asm.mov_imm(RAX, x.to_bits() as i64),
            ExprKind::Bool(b) => self.asm.mov_imm(RAX, *b as i64),
            ExprKind::Str(parts) => {
                let pieces: Vec<Piece> = parts
                    .iter()
                    .map(|p| match p {
                        StrPart::Lit(s) => Piece::Text(s.clone()),
                        StrPart::Expr(inner) => Piece::Expr(inner),
                    })
                    .collect();
                self.concat(&pieces);
            }
            ExprKind::Ident(name) => match self.lookup(name) {
                Some(var) => {
                    self.load_loc(RAX, var.loc);
                    if var.is_ref {
                        self.retain(RAX);
                    }
                }
                None if self.items.contains_key(name) => {
                    let closure = self.static_closure(name);
                    self.asm.lea(RAX, closure);
                }
                None => self.unsupported(e.span, "this kind of name used as a value"),
            },
            ExprKind::List(items) => {
                let td = self.descriptor(&ty);
                self.asm.lea(RAX, td);
                self.asm.push(RAX);
                self.asm.push_imm(items.len() as i32);
                self.call_runtime("__rt_list_new", 2);
                if items.is_empty() {
                    return;
                }
                // The list has room for every item: they are stored directly.
                self.asm.push(RAX);
                for (i, item) in items.iter().enumerate() {
                    self.expr(item);
                    self.asm.load(RCX, RSP, 0);
                    self.asm.load(RCX, RCX, LIST_DATA);
                    self.asm.store(RCX, 8 * i as i32, RAX);
                }
                self.asm.pop(RAX);
                self.asm.store_imm(RAX, LIST_LEN, items.len() as i32);
            }
            ExprKind::StructLit { name, fields, .. } => {
                let order: Vec<String> = self.an.structs[name].fields.iter().map(|(n, _)| n.clone()).collect();
                let td = self.descriptor(&ty);
                self.asm.lea(RAX, td);
                self.asm.push(RAX);
                self.asm.push_imm(FIELDS + 8 * order.len() as i32);
                self.call_runtime("__rt_new", 2);
                if order.is_empty() {
                    return;
                }
                self.asm.push(RAX);
                for (i, field) in order.iter().enumerate() {
                    let Some(init) = fields.iter().find(|f| &f.name == field) else { continue };
                    let offset = FIELDS + 8 * i as i32;
                    match self.simple(&init.value) {
                        Some(Operand::Imm(v)) => {
                            self.asm.load(RCX, RSP, 0);
                            self.asm.store_imm(RCX, offset, v as i32);
                        }
                        Some(Operand::At(Loc::Reg(r))) => {
                            self.asm.load(RCX, RSP, 0);
                            self.asm.store(RCX, offset, r);
                        }
                        _ => {
                            self.expr(&init.value);
                            self.asm.load(RCX, RSP, 0);
                            self.asm.store(RCX, offset, RAX);
                        }
                    }
                }
                self.asm.pop(RAX);
            }
            ExprKind::Unary { op: UnOp::Neg, expr } if ty == Type::Float => {
                // Only the sign bit changes.
                self.expr(expr);
                self.asm.mov_imm(RCX, i64::MIN);
                self.asm.alu(Alu::Xor, RAX, RCX);
            }
            ExprKind::Unary { op, expr } => {
                self.expr(expr);
                match op {
                    UnOp::Neg => self.asm.neg(RAX),
                    UnOp::Not => self.asm.alu_imm(Alu::Xor, RAX, 1),
                }
            }
            ExprKind::Binary { op, lhs, rhs } => {
                // Comparing a struct with an interface: let the objects tell their type.
                let (l, r) = (self.ty(lhs), self.ty(rhs));
                let operand_ty = if matches!(r, Type::Interface(_)) { r } else { l };
                match op {
                    BinOp::And | BinOp::Or => {
                        // Short-circuit: the right side only runs when it can change the result.
                        let end = self.asm.new_label();
                        self.expr(lhs);
                        self.asm.test(RAX, RAX);
                        self.asm.jcc(if *op == BinOp::And { Cc::E } else { Cc::Ne }, end);
                        self.expr(rhs);
                        self.asm.bind(end);
                    }
                    _ if operand_ty == Type::Str => self.string_binary(*op, lhs, rhs),
                    BinOp::Add | BinOp::Sub | BinOp::Mul | BinOp::Div | BinOp::Mod if operand_ty == Type::Float => {
                        self.float(e);
                        self.asm.movq_out(RAX, XMM0);
                    }
                    _ if operand_ty == Type::Float => {
                        let cc = self.float_compare(*op, lhs, rhs);
                        match cc {
                            Cc::E | Cc::Ne => {
                                // Equal only if both are numbers, too.
                                let unordered = self.asm.jcc_short(Cc::P);
                                self.asm.setcc(cc);
                                let done = self.asm.jmp_short();
                                self.asm.bind_short(unordered);
                                self.asm.mov_imm(RAX, (cc == Cc::Ne) as i64);
                                self.asm.bind_short(done);
                            }
                            _ => self.asm.setcc(cc),
                        }
                    }
                    _ if is_ref(&operand_ty) => {
                        // Lists and structs are compared by content.
                        self.call_rt("__rt_eq", &[Arg::Borrow(lhs), Arg::Borrow(rhs), Arg::Descriptor(operand_ty)], true);
                        if *op == BinOp::NotEq {
                            self.asm.alu_imm(Alu::Xor, RAX, 1);
                        }
                    }
                    BinOp::Add | BinOp::Sub | BinOp::Mul | BinOp::Div | BinOp::Mod => self.arith(*op, lhs, rhs),
                    _ => {
                        let cc = self.compare(*op, lhs, rhs);
                        self.asm.setcc(cc);
                    }
                }
            }
            ExprKind::Call { callee, args } => self.call(e, callee, args),
            // An error is its message.
            ExprKind::Field { obj, .. } if self.ty(obj) == Type::Error => self.expr(obj),
            ExprKind::Field { obj, name, .. } => {
                let Some(offset) = self.field_offset(obj, name) else {
                    self.unsupported(e.span, "fields of this type");
                    return;
                };
                if self.is_place(e) {
                    self.place(e);
                    if is_ref(&ty) {
                        self.retain(RAX);
                    }
                } else {
                    // The object is a temporary value: read the field, then drop it.
                    let owned = self.operand(obj);
                    if owned {
                        self.asm.push(RAX);
                    }
                    self.asm.load(RAX, RAX, offset);
                    if is_ref(&ty) {
                        self.retain(RAX);
                    }
                    if owned {
                        self.release_saved();
                    }
                }
            }
            ExprKind::Index { obj, index } if matches!(self.ty(obj), Type::Map(..)) => {
                let key = self.key_arg(index);
                self.call_rt("__rt_map_at", &[Arg::Borrow(obj), key], true);
            }
            ExprKind::Index { obj, index } if self.ty(obj) == Type::Str => {
                self.call_rt("__rt_str_index", &[Arg::Borrow(obj), Arg::Value(index)], true);
            }
            ExprKind::Index { obj, index } => {
                if self.is_place(e) {
                    self.place(e);
                    if is_ref(&ty) {
                        self.retain(RAX);
                    }
                } else {
                    let owned = self.operand(obj);
                    self.asm.push(RAX);
                    self.expr(index);
                    self.asm.load(RCX, RSP, 0);
                    self.element_address();
                    self.asm.load_indexed(RAX, RCX, RAX);
                    if is_ref(&ty) {
                        self.retain(RAX);
                    }
                    if owned {
                        self.release_saved();
                    } else {
                        self.asm.alu_imm(Alu::Add, RSP, 8);
                    }
                }
            }
            ExprKind::Try(call) => {
                // On failure the error goes straight to this function's caller.
                // The lowering pass made sure nothing else is pending here.
                self.expr(call);
                let fine = self.asm.new_label();
                self.asm.test(RDX, RDX);
                self.asm.jcc(Cc::E, fine);
                self.leave_with_error(RDX, None);
                self.asm.bind(fine);
            }
            ExprKind::Or { expr: call, default } => {
                self.expr(call);
                let fine = self.asm.new_label();
                self.asm.test(RDX, RDX);
                self.asm.jcc(Cc::E, fine);
                self.asm.mov(RAX, RDX);
                self.release_rax();
                self.expr(default);
                self.asm.bind(fine);
            }
            ExprKind::Catch { .. } => self.unsupported(e.span, "this use of `catch`"),
            ExprKind::Range { .. } => self.unsupported(e.span, "ranges outside of a `for` loop"),
            ExprKind::Map(entries) => {
                let td = self.descriptor(&ty);
                self.asm.lea(RAX, td);
                self.asm.push(RAX);
                self.call_runtime("__rt_map_new", 1);
                if entries.is_empty() {
                    return;
                }
                self.asm.push(RAX);
                for (key, value) in entries {
                    self.asm.load(RAX, RSP, 0);
                    self.asm.push(RAX);
                    let key_owned = self.push_arg(key);
                    self.expr(value);
                    self.asm.push(RAX);
                    self.call_runtime("__rt_map_set", 0);
                    self.drop_args(&[false, key_owned, false], false);
                }
                self.asm.pop(RAX);
            }
            ExprKind::Lambda { .. } => {
                let key = lambda_key(e.id);
                let captures = self.an.captures.get(&e.id).cloned().unwrap_or_default();
                if captures.is_empty() {
                    let closure = self.static_closure(&key);
                    self.asm.lea(RAX, closure);
                    return;
                }
                // The closure: the address of the code, then what it captures.
                let types: Vec<Type> = captures.iter().map(|(_, ty)| ty.clone()).collect();
                for ty in &types {
                    self.check_type(ty, e.span);
                }
                let td = self.closure_descriptor(&types);
                self.asm.lea(RAX, td);
                self.asm.push(RAX);
                self.asm.push_imm(FIELDS + 8 * (1 + captures.len() as i32));
                self.call_runtime("__rt_new", 2);
                let code = self.function_label(&key);
                self.asm.lea(RCX, code);
                self.asm.store(RAX, FIELDS, RCX);
                for (i, (name, ty)) in captures.iter().enumerate() {
                    let Some(var) = self.lookup(name) else { continue };
                    self.load_loc(RCX, var.loc);
                    if is_ref(ty) {
                        self.retain(RCX);
                    }
                    self.asm.store(RAX, FIELDS + 8 + 8 * i as i32, RCX);
                }
            }
            ExprKind::Recv(_) | ExprKind::ChanNew { .. } => self.unsupported(e.span, "channels"),
        }
    }

    /// Evaluates `e` to use it right away. A local variable or a constant is
    /// read without counting a new reference; the result says whether the
    /// caller received a reference it has to release.
    fn operand(&mut self, e: &Expr) -> bool {
        if let Some(var) = self.local(e) {
            self.load_loc(RAX, var.loc);
            return false;
        }
        if let ExprKind::Str(parts) = &e.kind {
            if let Some(text) = plain(parts) {
                let label = self.string(text);
                self.asm.lea(RAX, label);
                return false;
            }
        }
        self.expr(e);
        is_ref(&self.ty(e))
    }

    /// Like `operand`, but also borrows from top-level variables, fields and
    /// list elements. Only valid when the value is consumed before any code of
    /// the program can run again (which could replace what was borrowed).
    fn operand_now(&mut self, e: &Expr) -> bool {
        if self.is_place(e) {
            self.place(e);
            false
        } else {
            self.operand(e)
        }
    }

    /// Is `e` a variable, or a field or element reached from one without calling anything?
    fn is_place(&self, e: &Expr) -> bool {
        match &e.kind {
            ExprKind::Ident(name) => self.lookup(name).is_some(),
            ExprKind::Field { obj, .. } => matches!(self.ty(obj), Type::Struct(_)) && self.is_place(obj),
            ExprKind::Index { obj, index } => {
                matches!(self.ty(obj), Type::List(_)) && self.is_place(obj) && self.is_pure(index)
            }
            _ => false,
        }
    }

    /// Loads the value of a place into RAX, without counting a reference.
    fn place(&mut self, e: &Expr) {
        match &e.kind {
            ExprKind::Ident(name) => {
                if let Some(var) = self.lookup(name) {
                    self.load_loc(RAX, var.loc);
                }
            }
            ExprKind::Field { obj, name, .. } => {
                let offset = self.field_offset(obj, name).unwrap_or(0);
                match self.local(obj) {
                    Some(VarRef { loc: Loc::Reg(r), .. }) => self.asm.load(RAX, r, offset),
                    _ => {
                        self.place(obj);
                        self.asm.load(RAX, RAX, offset);
                    }
                }
            }
            ExprKind::Index { obj, index } => {
                match self.simple(index) {
                    Some(position) => {
                        self.place(obj);
                        self.asm.mov(RCX, RAX);
                        self.load_operand(RAX, position);
                    }
                    None => {
                        self.place(obj);
                        self.asm.push(RAX);
                        self.expr(index);
                        self.asm.pop(RCX);
                    }
                }
                self.element_address();
                self.asm.load_indexed(RAX, RCX, RAX);
            }
            _ => self.expr(e),
        }
    }

    /// Evaluating `e` runs no code of the program: only reads, arithmetic and
    /// runtime helpers. Nothing a pure expression does can release an object.
    fn is_pure(&self, e: &Expr) -> bool {
        match &e.kind {
            ExprKind::Int(_) | ExprKind::Float(_) | ExprKind::Bool(_) => true,
            ExprKind::Str(parts) => parts.iter().all(|p| match p {
                StrPart::Lit(_) => true,
                StrPart::Expr(inner) => self.is_pure(inner),
            }),
            ExprKind::Ident(name) => self.lookup(name).is_some(),
            ExprKind::Unary { expr, .. } => self.is_pure(expr),
            ExprKind::Binary { lhs, rhs, .. } => self.is_pure(lhs) && self.is_pure(rhs),
            ExprKind::Field { obj, .. } => matches!(self.ty(obj), Type::Struct(_)) && self.is_pure(obj),
            ExprKind::Index { obj, index } => {
                matches!(self.ty(obj), Type::List(_) | Type::Str) && self.is_pure(obj) && self.is_pure(index)
            }
            ExprKind::Call { callee, args } => {
                let receiver_pure = match &callee.kind {
                    ExprKind::Field { obj, .. } => self.is_pure(obj),
                    _ => true,
                };
                let harmless = match self.call_kind(e) {
                    Some(CallKind::Builtin(name)) => matches!(
                        name.as_str(),
                        "str" | "abs" | "min" | "max" | "float" | "int" | "sqrt" | "pow" | "floor" | "ceil" | "round"
                    ),
                    // Strings never change: all their methods only read them.
                    Some(CallKind::BuiltinMethod(Recv::Str, _)) => true,
                    Some(CallKind::BuiltinMethod(_, name)) => matches!(name.as_str(), "len" | "contains" | "index_of"),
                    _ => false,
                };
                harmless && receiver_pure && args.iter().all(|a| self.is_pure(a))
            }
            _ => false,
        }
    }

    fn field_offset(&self, obj: &Expr, field: &str) -> Option<i32> {
        let Type::Struct(name) = self.ty(obj) else { return None };
        let index = self.an.structs[&name].fields.iter().position(|(n, _)| n == field)?;
        Some(FIELDS + 8 * index as i32)
    }

    /// With a list in RCX and a position in RAX: checks the position, then
    /// leaves the address of the list's elements in RCX (the element is at
    /// `[RCX + RAX * 8]`).
    fn element_address(&mut self) {
        // Unsigned comparison: a negative position looks huge.
        self.asm.alu_load(Alu::Cmp, RAX, RCX, LIST_LEN);
        let out_of_bounds = self.index_oob_label();
        self.asm.jcc(Cc::Ae, out_of_bounds);
        self.asm.load(RCX, RCX, LIST_DATA);
    }

    // ---- expressions: strings ----

    /// Evaluates `e` and converts it to a string in RAX. Returns whether the
    /// caller owns that string.
    fn to_str(&mut self, e: &Expr) -> bool {
        let ty = self.ty(e);
        match ty {
            Type::Str | Type::Error => {
                self.expr(e);
                true
            }
            Type::Int => {
                self.push_value(e);
                self.call_runtime("__rt_int_str", 1);
                true
            }
            Type::Float => {
                self.push_value(e);
                self.call_runtime("__rt_float_str", 1);
                true
            }
            Type::Bool => {
                let (yes, no) = (self.string("true"), self.string("false"));
                self.expr(e);
                self.asm.test(RAX, RAX);
                self.asm.lea(RAX, no);
                let done = self.asm.jcc_short(Cc::E);
                self.asm.lea(RAX, yes);
                self.asm.bind_short(done);
                false
            }
            _ => {
                self.call_rt("__rt_repr", &[Arg::Borrow(e), Arg::Descriptor(ty), Arg::Const(0)], true);
                true
            }
        }
    }

    /// Pushes the pieces of a string, each as a string. Returns which ones
    /// have to be released afterwards, and how many bytes of the stack, above
    /// the pieces, hold the text of numbers.
    fn push_pieces(&mut self, pieces: &[Piece]) -> (Vec<bool>, i32) {
        // When no piece runs code of the program, strings can be borrowed
        // from wherever they are stored.
        let pure = pieces.iter().all(|p| match p {
            Piece::Text(_) => true,
            Piece::Expr(e) => self.is_pure(e),
        });
        // A number becomes text in a small buffer on the stack, reserved here:
        // showing it allocates nothing.
        let numbers = pieces.iter().filter(|p| matches!(p, Piece::Expr(e) if self.ty(e) == Type::Int)).count() as i32;
        if numbers > 0 {
            self.asm.alu_imm(Alu::Sub, RSP, NUMBER_BUFFER * numbers);
        }
        let mut used = 0;
        let mut owned = Vec::new();
        for (pushed, piece) in pieces.iter().enumerate() {
            owned.push(match piece {
                Piece::Text(text) => {
                    let label = self.string(text);
                    self.asm.lea(RAX, label);
                    false
                }
                Piece::Expr(e) if matches!(self.ty(e), Type::Str | Type::Error) => {
                    if pure {
                        self.operand_now(e)
                    } else {
                        self.operand(e)
                    }
                }
                Piece::Expr(e) if self.ty(e) == Type::Int => {
                    self.expr(e);
                    self.asm.lea_mem(RCX, RSP, 8 * pushed as i32 + NUMBER_BUFFER * used);
                    self.asm.push(RCX);
                    self.asm.push(RAX);
                    self.call_runtime("__rt_int_into", 2);
                    used += 1;
                    false
                }
                Piece::Expr(e) => self.to_str(e),
            });
            self.asm.push(RAX);
        }
        (owned, NUMBER_BUFFER * numbers)
    }

    /// Removes what `push_pieces` left on the stack, releasing the temporary strings.
    fn drop_pieces(&mut self, pieces: (Vec<bool>, i32), keep_result: bool) {
        self.drop_args(&pieces.0, keep_result);
        if pieces.1 > 0 {
            self.asm.alu_imm(Alu::Add, RSP, pieces.1);
        }
    }

    /// Builds one string out of pieces; leaves it, owned, in RAX.
    fn concat(&mut self, pieces: &[Piece]) {
        match pieces {
            [] => {
                let empty = self.string("");
                self.asm.lea(RAX, empty);
            }
            [Piece::Text(text)] => {
                let label = self.string(text);
                self.asm.lea(RAX, label);
            }
            [Piece::Expr(e)] => {
                self.to_str(e);
            }
            [Piece::Expr(a), Piece::Expr(b)] if self.ty(a) == Type::Str && self.ty(b) == Type::Str => {
                self.call_rt("__rt_concat", &[Arg::Borrow(a), Arg::Borrow(b)], true);
            }
            _ => {
                // One allocation for the whole string, whatever the number of pieces.
                let pushed = self.push_pieces(pieces);
                self.asm.mov(RAX, RSP);
                self.asm.push(RAX);
                self.asm.push_imm(pieces.len() as i32);
                self.call_runtime("__rt_concat_n", 2);
                self.drop_pieces(pushed, true);
            }
        }
    }

    /// An operation on two strings; the result goes to RAX.
    fn string_binary(&mut self, op: BinOp, lhs: &Expr, rhs: &Expr) {
        match op {
            BinOp::Add => {
                // `a + b + c` is assembled in one go.
                fn leaves<'e>(e: &'e Expr, out: &mut Vec<Piece<'e>>) {
                    match &e.kind {
                        ExprKind::Binary { op: BinOp::Add, lhs, rhs } => {
                            leaves(lhs, out);
                            leaves(rhs, out);
                        }
                        ExprKind::Str(parts) => match plain(parts) {
                            Some(text) => out.push(Piece::Text(text.to_string())),
                            None => out.push(Piece::Expr(e)),
                        },
                        _ => out.push(Piece::Expr(e)),
                    }
                }
                let mut pieces = Vec::new();
                leaves(lhs, &mut pieces);
                leaves(rhs, &mut pieces);
                self.concat(&pieces);
            }
            BinOp::Eq | BinOp::NotEq => {
                self.call_rt("__rt_str_eq", &[Arg::Borrow(lhs), Arg::Borrow(rhs)], true);
                if op == BinOp::NotEq {
                    self.asm.alu_imm(Alu::Xor, RAX, 1);
                }
            }
            _ => {
                // Ordering: compare the result of str_cmp with zero.
                self.call_rt("__rt_str_cmp", &[Arg::Borrow(lhs), Arg::Borrow(rhs)], true);
                self.asm.alu_imm(Alu::Cmp, RAX, 0);
                self.asm.setcc(cc_of(op));
            }
        }
    }

    // ---- expressions: arithmetic ----

    /// `lhs op rhs` on integers; the result goes to RAX.
    fn arith(&mut self, op: BinOp, lhs: &Expr, rhs: &Expr) {
        match self.simple(rhs) {
            Some(Operand::Imm(v)) => {
                self.expr(lhs);
                self.arith_imm(op, v);
            }
            Some(right) => {
                self.expr(lhs);
                self.arith_operand(op, right);
            }
            None => match self.simple(lhs) {
                // The left side is a constant or a local variable: computing
                // the right side first cannot change it.
                Some(left) if !matches!(left, Operand::At(Loc::Global(_))) => {
                    self.expr(rhs);
                    match (op, left) {
                        (BinOp::Add | BinOp::Mul, Operand::Imm(v)) => self.arith_imm(op, v),
                        (BinOp::Add | BinOp::Mul, _) => self.arith_operand(op, left),
                        _ => {
                            self.asm.mov(RCX, RAX);
                            self.load_operand(RAX, left);
                            self.arith_rcx(op);
                        }
                    }
                }
                _ => {
                    self.expr(lhs);
                    self.asm.push(RAX);
                    self.expr(rhs);
                    self.asm.mov(RCX, RAX);
                    self.asm.pop(RAX);
                    self.arith_rcx(op);
                }
            },
        }
    }

    /// `RAX = RAX op RCX`
    fn arith_rcx(&mut self, op: BinOp) {
        match op {
            BinOp::Add => self.asm.alu(Alu::Add, RAX, RCX),
            BinOp::Sub => self.asm.alu(Alu::Sub, RAX, RCX),
            BinOp::Mul => self.asm.imul(RAX, RCX),
            _ => self.divide(op == BinOp::Mod),
        }
    }

    /// `RAX = RAX op variable`
    fn arith_operand(&mut self, op: BinOp, operand: Operand) {
        match (op, operand) {
            (BinOp::Add, _) => self.operand_alu(Alu::Add, RAX, operand),
            (BinOp::Sub, _) => self.operand_alu(Alu::Sub, RAX, operand),
            (BinOp::Mul, Operand::At(Loc::Reg(r))) => self.asm.imul(RAX, r),
            (BinOp::Mul, Operand::At(Loc::Frame(offset))) => self.asm.imul_load(RAX, RBP, offset),
            (BinOp::Mul, Operand::At(Loc::Global(offset))) => self.asm.imul_load(RAX, R15, offset),
            _ => {
                self.load_operand(RCX, operand);
                self.divide(op == BinOp::Mod);
            }
        }
    }

    /// `RAX = RAX op constant`
    fn arith_imm(&mut self, op: BinOp, v: i64) {
        match op {
            BinOp::Add if v != 0 => self.asm.alu_imm(Alu::Add, RAX, v as i32),
            BinOp::Sub if v != 0 => self.asm.alu_imm(Alu::Sub, RAX, v as i32),
            BinOp::Add | BinOp::Sub => {}
            BinOp::Mul => match v {
                0 => self.asm.mov_imm(RAX, 0),
                1 => {}
                -1 => self.asm.neg(RAX),
                _ if v > 0 && (v as u64).is_power_of_two() => self.asm.shift(Shift::Left, RAX, v.trailing_zeros() as u8),
                _ => self.asm.imul_imm(RAX, RAX, v as i32),
            },
            _ => self.divide_by(v, op == BinOp::Mod),
        }
    }

    /// RAX / RCX (or RAX % RCX), with a panic on division by zero.
    fn divide(&mut self, remainder: bool) {
        self.asm.test(RCX, RCX);
        let zero = self.div_zero_label();
        self.asm.jcc(Cc::E, zero);
        // The processor traps on MIN / -1, so dividing by -1 is done by hand.
        self.asm.alu_imm(Alu::Cmp, RCX, -1);
        let plain = self.asm.jcc_short(Cc::Ne);
        if remainder {
            self.asm.mov_imm(RAX, 0);
        } else {
            self.asm.neg(RAX);
        }
        let done = self.asm.jmp_short();
        self.asm.bind_short(plain);
        self.asm.cqo();
        self.asm.idiv(RCX);
        if remainder {
            self.asm.mov(RAX, RDX);
        }
        self.asm.bind_short(done);
    }

    /// RAX / d (or RAX % d) for a constant `d`, without a division instruction.
    fn divide_by(&mut self, d: i64, remainder: bool) {
        if d == 0 {
            let zero = self.div_zero_label();
            self.asm.jmp(zero);
            return;
        }
        let abs = d.unsigned_abs();
        if abs == 1 {
            if remainder {
                self.asm.mov_imm(RAX, 0);
            } else if d < 0 {
                self.asm.neg(RAX);
            }
            return;
        }
        if abs.is_power_of_two() {
            // Rounding goes towards zero: negative numbers get (2^k - 1) added first.
            let k = abs.trailing_zeros() as u8;
            self.asm.mov(RCX, RAX);
            self.asm.shift(Shift::RightSigned, RCX, 63);
            self.asm.shift(Shift::Right, RCX, 64 - k);
            self.asm.alu(Alu::Add, RAX, RCX);
            if remainder {
                self.asm.alu_imm(Alu::And, RAX, (abs - 1) as i32);
                self.asm.alu(Alu::Sub, RAX, RCX);
            } else {
                self.asm.shift(Shift::RightSigned, RAX, k);
                if d < 0 {
                    self.asm.neg(RAX);
                }
            }
            return;
        }
        // The remainder has the sign of the dividend, whatever the divisor's.
        let divisor = if remainder { abs as i64 } else { d };
        let (magic, shift) = magic_number(divisor);
        self.asm.mov(RCX, RAX);
        self.asm.mov_imm(RAX, magic);
        self.asm.imul_wide(RCX);
        if divisor > 0 && magic < 0 {
            self.asm.alu(Alu::Add, RDX, RCX);
        }
        if divisor < 0 && magic > 0 {
            self.asm.alu(Alu::Sub, RDX, RCX);
        }
        if shift > 0 {
            self.asm.shift(Shift::RightSigned, RDX, shift);
        }
        self.asm.mov(RAX, RDX);
        self.asm.shift(Shift::Right, RAX, 63);
        self.asm.alu(Alu::Add, RAX, RDX);
        if remainder {
            self.asm.imul_imm(RAX, RAX, abs as i32);
            self.asm.alu(Alu::Sub, RCX, RAX);
            self.asm.mov(RAX, RCX);
        }
    }

    // ---- expressions: calls ----

    /// Pushes an argument. A reference held by a local variable is lent as
    /// is; anything else is a temporary value, to release after the call.
    fn push_arg(&mut self, e: &Expr) -> bool {
        if is_ref(&self.ty(e)) {
            let owned = self.operand(e);
            self.asm.push(RAX);
            owned
        } else {
            self.push_value(e);
            false
        }
    }

    /// Calls a runtime function. The runtime never runs code of the program,
    /// so when the arguments do not either, references can be borrowed from
    /// wherever they are stored.
    /// Like `call_rt`, for a runtime function that can fail.
    fn call_rt_fallible(&mut self, name: &str, args: &[Arg], has_result: bool) {
        self.rt_fallible = true;
        self.call_rt(name, args, has_result);
    }

    fn call_rt(&mut self, name: &str, args: &[Arg], has_result: bool) {
        let fallible = std::mem::take(&mut self.rt_fallible);
        let pure = args.iter().all(|arg| match arg {
            Arg::Borrow(e) | Arg::Move(e) | Arg::Value(e) => self.is_pure(e),
            _ => true,
        });
        let mut owned = Vec::new();
        for arg in args {
            owned.push(match arg {
                Arg::Borrow(e) => {
                    let owned = if pure { self.operand_now(e) } else { self.operand(e) };
                    self.asm.push(RAX);
                    owned
                }
                Arg::Move(e) => {
                    self.expr(e);
                    self.asm.push(RAX);
                    false
                }
                Arg::Value(e) => {
                    self.push_value(e);
                    false
                }
                Arg::Const(v) => {
                    self.asm.push_imm(*v as i32);
                    false
                }
                Arg::Descriptor(ty) => {
                    let td = self.descriptor(ty);
                    self.asm.lea(RAX, td);
                    self.asm.push(RAX);
                    false
                }
            });
        }
        self.call_runtime(name, 0);
        self.keep_error = fallible;
        self.drop_args(&owned, has_result);
    }

    fn call(&mut self, e: &Expr, callee: &Expr, args: &[Expr]) {
        let has_result = self.ty(e) != Type::Void;
        let fallible = self.an.fallible_calls.contains(&e.id);
        match self.call_kind(e).cloned() {
            Some(CallKind::Fn(name)) => {
                let owned: Vec<bool> = args.iter().map(|a| self.push_arg(a)).collect();
                let label = self.function_label(&name);
                self.asm.call(label);
                self.keep_error = fallible;
                self.drop_args(&owned, has_result);
            }
            Some(CallKind::Method(strukt, name)) => {
                // `self` is the first argument.
                let ExprKind::Field { obj, .. } = &callee.kind else { return };
                let mut owned = vec![self.push_arg(obj)];
                owned.extend(args.iter().map(|a| self.push_arg(a)));
                let label = self.function_label(&method_key(&strukt, &name));
                self.asm.call(label);
                self.keep_error = fallible;
                self.drop_args(&owned, has_result);
            }
            Some(CallKind::Dynamic) if !matches!(&callee.kind, ExprKind::Field { obj, .. } if matches!(self.ty(obj), Type::Interface(_))) => {
                // A call through a function value: the closure waits under
                // the arguments, and travels to its code in R10.
                let mut owned = vec![self.push_arg(callee)];
                owned.extend(args.iter().map(|a| self.push_arg(a)));
                self.asm.load(R10, RSP, 8 * args.len() as i32);
                self.asm.call_mem(R10, FIELDS);
                self.keep_error = fallible;
                self.drop_args(&owned, has_result);
            }
            Some(CallKind::Dynamic) => {
                let ExprKind::Field { obj, name, .. } = &callee.kind else { return };
                let mut owned = vec![self.push_arg(obj)];
                owned.extend(args.iter().map(|a| self.push_arg(a)));
                self.interface_call(name, args.len());
                self.keep_error = fallible;
                self.drop_args(&owned, has_result);
            }
            Some(CallKind::Builtin(name)) => self.builtin(&name, e, args),
            Some(CallKind::BuiltinMethod(Recv::Str, name)) => {
                let ExprKind::Field { obj, .. } = &callee.kind else { return };
                self.string_method(e, obj, &name, args);
            }
            Some(CallKind::BuiltinMethod(Recv::List, name)) => {
                let ExprKind::Field { obj, .. } = &callee.kind else { return };
                self.list_method(e, obj, &name, args);
            }
            Some(CallKind::BuiltinMethod(Recv::Map, name)) => {
                let ExprKind::Field { obj, .. } = &callee.kind else { return };
                self.map_method(e, obj, &name, args);
            }
            Some(CallKind::BuiltinMethod(_, name)) => {
                self.unsupported(e.span, &format!("calls to the method `{name}`"));
            }
            None => self.unsupported(e.span, "calls through function values"),
        }
    }

    /// Calls the method `name` of the object pushed `args + 1` slots ago,
    /// whose struct is only known when the program runs. Each call site
    /// remembers the last type it saw and the method it found for it, so the
    /// search only happens when the type changes.
    fn interface_call(&mut self, name: &str, args: usize) {
        let cache = STATE_SIZE + 8 * self.globals.len() as i32 + 16 * self.caches as i32;
        self.caches += 1;
        self.asm.load(RAX, RSP, 8 * args as i32);
        self.asm.load32(RCX, RAX, DESCRIPTOR);
        self.asm.alu_load(Alu::Cmp, RCX, R15, cache);
        let miss = self.asm.jcc_short(Cc::Ne);
        self.asm.call_mem(R15, cache + 8);
        let done = self.asm.jmp_short();
        self.asm.bind_short(miss);
        self.asm.store(R15, cache, RCX);
        self.asm.push(RAX);
        let name_label = self.string(name);
        self.asm.lea(RAX, name_label);
        self.asm.push(RAX);
        self.call_runtime("__rt_find_method", 2);
        self.asm.store(R15, cache + 8, RAX);
        self.asm.call_reg(RAX);
        self.asm.bind_short(done);
    }

    /// A map key as an argument for the runtime: strings are lent, the rest is a plain value.
    fn key_arg<'e>(&self, key: &'e Expr) -> Arg<'e> {
        if is_ref(&self.ty(key)) {
            Arg::Borrow(key)
        } else {
            Arg::Value(key)
        }
    }

    fn map_method(&mut self, e: &Expr, obj: &Expr, name: &str, args: &[Expr]) {
        let Type::Map(key_ty, value_ty) = self.ty(obj) else { return };
        match name {
            "len" => {
                let owned = self.operand(obj);
                if owned {
                    self.asm.push(RAX);
                }
                self.asm.load(RAX, RAX, 8);
                if owned {
                    self.release_saved();
                }
            }
            "get" => {
                let key = self.key_arg(&args[0]);
                self.call_rt_fallible("__rt_map_get", &[Arg::Borrow(obj), key], true);
            }
            "has" => {
                let key = self.key_arg(&args[0]);
                self.call_rt("__rt_map_has", &[Arg::Borrow(obj), key], true);
            }
            "remove" => {
                let key = self.key_arg(&args[0]);
                self.call_rt("__rt_map_remove", &[Arg::Borrow(obj), key], false);
            }
            "clear" => self.call_rt("__rt_map_clear", &[Arg::Borrow(obj)], false),
            "keys" => {
                let list = Arg::Descriptor(Type::List(key_ty));
                self.call_rt("__rt_map_list", &[Arg::Borrow(obj), list, Arg::Const(8)], true);
            }
            "values" => {
                let list = Arg::Descriptor(Type::List(value_ty));
                self.call_rt("__rt_map_list", &[Arg::Borrow(obj), list, Arg::Const(16)], true);
            }
            _ => self.unsupported(e.span, &format!("calls to the map method `{name}`")),
        }
    }

    /// `map[key] = value` and `map[key] op= value`.
    fn assign_entry(&mut self, obj: &Expr, key: &Expr, ty: &Type, bin: Option<BinOp>, value: &Expr) {
        let Some(op) = bin else {
            let key = self.key_arg(key);
            let value = if is_ref(ty) { Arg::Move(value) } else { Arg::Value(value) };
            self.call_rt("__rt_map_set", &[Arg::Borrow(obj), key, value], false);
            return;
        };
        // The map and the key wait on the stack while the new value is computed.
        let map_owned = self.operand(obj);
        self.asm.push(RAX);
        let key_owned = self.push_arg(key);
        self.asm.load(RAX, RSP, 8);
        self.asm.push(RAX);
        self.asm.load(RAX, RSP, 8);
        self.asm.push(RAX);
        self.call_runtime("__rt_map_at", 2);
        if *ty == Type::Str {
            self.asm.push(RAX);
            let piece_owned = self.operand(value);
            self.asm.push(RAX);
            self.call_runtime("__rt_concat", 0);
            self.drop_args(&[true, piece_owned], true);
        } else {
            self.asm.push(RAX);
            self.expr(value);
            self.asm.mov(RCX, RAX);
            self.asm.pop(RAX);
            self.arith_rcx(op);
        }
        self.asm.push(RAX);
        self.call_runtime("__rt_map_set", 1);
        self.drop_args(&[map_owned, key_owned], false);
    }

    /// `for key in map`: the keys, in the order they were added.
    fn for_map(&mut self, var: &str, var_span: Span, iter: &Expr, body: &Block, key: &Type) {
        let (top, next, end) = (self.asm.new_label(), self.asm.new_label(), self.asm.new_label());
        // Outer scope: the map (kept alive for the whole loop) and the entry number.
        self.scopes.push(Vec::new());
        self.expr(iter);
        let map = self.declare("<map>", (var_span.start, SUBJECT), &self.ty(iter));
        self.store_loc(map, RAX);
        let position = self.home((var_span.start, COUNTER));
        self.asm.mov_imm(RAX, 0);
        self.store_loc(position, RAX);

        self.asm.bind(top);
        // Removed entries are skipped; the search starts where the last turn stopped.
        self.load_loc(RAX, map);
        self.asm.push(RAX);
        self.load_loc(RAX, position);
        self.asm.push(RAX);
        self.call_runtime("__rt_map_next", 2);
        self.asm.alu_imm(Alu::Cmp, RAX, 0);
        self.asm.jcc(Cc::L, end);
        self.store_loc(position, RAX);
        self.load_loc(RCX, map);
        self.asm.push(RCX);
        self.asm.push(RAX);
        self.asm.push_imm(8);
        self.call_runtime("__rt_map_part", 3);

        // Inner scope: the loop variable, released after each turn.
        self.scopes.push(Vec::new());
        if is_ref(key) {
            self.retain(RAX);
        }
        let item = self.declare(var, (var_span.start, NAMED), key);
        self.store_loc(item, RAX);
        let depth = self.scopes.len();
        self.loops.push(Loop { next, end, continue_from: depth, break_from: depth - 1 });
        self.block(body);
        self.loops.pop();

        self.asm.bind(next);
        self.release_scopes(depth - 1);
        self.scopes.pop();
        self.load_loc(RAX, position);
        self.asm.alu_imm(Alu::Add, RAX, 1);
        self.store_loc(position, RAX);
        self.asm.jmp(top);

        self.asm.bind(end);
        self.release_scopes(self.scopes.len() - 1);
        self.scopes.pop();
    }

    // ---- floats ----
    //
    // A float is stored like everything else, in 8 bytes: variables, fields,
    // list elements and RAX hold its bits. Computing happens in XMM0 and
    // XMM1; a whole expression such as `a * b + c * d` stays there, and only
    // its result goes back to RAX.

    /// Loads the float stored at `loc`.
    fn float_load(&mut self, dst: Xmm, loc: Loc) {
        match loc {
            Loc::Reg(r) => self.asm.movq_in(dst, r),
            Loc::Frame(offset) => self.asm.sse_load(Sse::Mov, dst, RBP, offset),
            Loc::Global(offset) => self.asm.sse_load(Sse::Mov, dst, R15, offset),
        }
    }

    /// Evaluates the float `e` into XMM0.
    fn float(&mut self, e: &Expr) {
        match &e.kind {
            ExprKind::Float(x) => {
                self.asm.mov_imm(RAX, x.to_bits() as i64);
                self.asm.movq_in(XMM0, RAX);
            }
            ExprKind::Binary { op: BinOp::Mod, lhs, rhs } if self.ty(e) == Type::Float => {
                // The remainder comes from the processor's older floating-point
                // unit, whose `fprem` is exact; it works on memory operands.
                self.float(lhs);
                self.asm.movq_out(RAX, XMM0);
                self.asm.push(RAX);
                self.float(rhs);
                self.asm.movq_out(RAX, XMM0);
                self.asm.push(RAX);
                self.asm.bytes(&[0xDD, 0x04, 0x24]); // fld qword [rsp]      the divisor
                self.asm.bytes(&[0xDD, 0x44, 0x24, 0x08]); // fld qword [rsp+8]  the dividend
                self.asm.bytes(&[0xD9, 0xF8]); // fprem: a partial remainder...
                self.asm.bytes(&[0xDF, 0xE0]); // fnstsw ax
                self.asm.bytes(&[0xF6, 0xC4, 0x04]); // test ah, 4
                self.asm.bytes(&[0x75, 0xF7]); // jnz fprem: ...until it is complete
                self.asm.bytes(&[0xDD, 0x5C, 0x24, 0x08]); // fstp qword [rsp+8]
                self.asm.bytes(&[0xDD, 0xD8]); // fstp st(0)
                self.asm.pop(RAX);
                self.asm.pop(RAX);
                self.asm.movq_in(XMM0, RAX);
            }
            ExprKind::Binary { op: op @ (BinOp::Add | BinOp::Sub | BinOp::Mul | BinOp::Div), lhs, rhs }
                if self.ty(e) == Type::Float =>
            {
                let op = match op {
                    BinOp::Add => Sse::Add,
                    BinOp::Sub => Sse::Sub,
                    BinOp::Mul => Sse::Mul,
                    _ => Sse::Div,
                };
                // When the left side is a plain read and the right side a
                // computation that runs no code of the program, the right
                // side goes first: nothing has to wait on the stack.
                let leaf = matches!(lhs.kind, ExprKind::Ident(_) | ExprKind::Float(_) | ExprKind::Field { .. } | ExprKind::Index { .. });
                if leaf && self.simple(rhs).is_none() && !matches!(rhs.kind, ExprKind::Float(_)) && self.is_pure(lhs) && self.is_pure(rhs) {
                    self.float(rhs);
                    self.asm.sse(Sse::Mov, XMM1, XMM0);
                    self.float(lhs);
                    self.asm.sse(op, XMM0, XMM1);
                    return;
                }
                self.float(lhs);
                match (self.simple(rhs), &rhs.kind) {
                    (Some(Operand::At(Loc::Reg(r))), _) => {
                        self.asm.movq_in(XMM1, r);
                        self.asm.sse(op, XMM0, XMM1);
                    }
                    (Some(Operand::At(Loc::Frame(offset))), _) => self.asm.sse_load(op, XMM0, RBP, offset),
                    (Some(Operand::At(Loc::Global(offset))), _) => self.asm.sse_load(op, XMM0, R15, offset),
                    (_, ExprKind::Float(x)) => {
                        self.asm.mov_imm(RAX, x.to_bits() as i64);
                        self.asm.movq_in(XMM1, RAX);
                        self.asm.sse(op, XMM0, XMM1);
                    }
                    _ => {
                        self.float_second(rhs);
                        self.asm.sse(op, XMM0, XMM1);
                    }
                }
            }
            ExprKind::Call { args, .. } => match self.call_kind(e) {
                Some(CallKind::Builtin(name)) if name == "float" && self.ty(&args[0]) == Type::Int => {
                    self.expr(&args[0]);
                    // Clearing the register first tells the processor that
                    // its old content does not matter.
                    self.asm.pxor(XMM0, XMM0);
                    self.asm.cvtsi2sd(XMM0, RAX);
                }
                Some(CallKind::Builtin(name)) if name == "float" => self.float(&args[0]),
                Some(CallKind::Builtin(name)) if name == "sqrt" => {
                    self.float(&args[0]);
                    self.asm.sse(Sse::Sqrt, XMM0, XMM0);
                }
                _ => {
                    self.expr(e);
                    self.asm.movq_in(XMM0, RAX);
                }
            },
            _ => match self.simple(e) {
                Some(Operand::At(loc)) => self.float_load(XMM0, loc),
                _ => {
                    self.expr(e);
                    self.asm.movq_in(XMM0, RAX);
                }
            },
        }
    }

    /// With a first operand in XMM0: evaluates `e` into XMM1, keeping XMM0.
    fn float_second(&mut self, e: &Expr) {
        match (self.simple(e), &e.kind) {
            (Some(Operand::At(loc)), _) => self.float_load(XMM1, loc),
            (_, ExprKind::Float(x)) => {
                self.asm.mov_imm(RAX, x.to_bits() as i64);
                self.asm.movq_in(XMM1, RAX);
            }
            _ => {
                // Computing it uses XMM0, and may call functions: the first
                // operand waits on the stack.
                self.asm.movq_out(RAX, XMM0);
                self.asm.push(RAX);
                self.float(e);
                self.asm.sse(Sse::Mov, XMM1, XMM0);
                self.asm.pop(RAX);
                self.asm.movq_in(XMM0, RAX);
            }
        }
    }

    /// Compares two floats and returns the condition under which
    /// `lhs op rhs` holds. For `E` and `Ne` the caller must also look at the
    /// parity flag, set when one of them is not a number; the other
    /// conditions are false by themselves in that case.
    fn float_compare(&mut self, op: BinOp, lhs: &Expr, rhs: &Expr) -> Cc {
        self.float(lhs);
        self.float_second(rhs);
        match op {
            // `a < b` is "b is above a".
            BinOp::Lt | BinOp::Le => self.asm.ucomisd(XMM1, XMM0),
            _ => self.asm.ucomisd(XMM0, XMM1),
        }
        match op {
            BinOp::Lt | BinOp::Gt => Cc::A,
            BinOp::Le | BinOp::Ge => Cc::Ae,
            BinOp::Eq => Cc::E,
            _ => Cc::Ne,
        }
    }

    fn string_method(&mut self, e: &Expr, obj: &Expr, name: &str, args: &[Expr]) {
        let text = Arg::Borrow(obj);
        let strings = Arg::Descriptor(Type::List(Box::new(Type::Str)));
        match name {
            "len" => self.call_rt("__rt_str_len", &[text], true),
            "upper" => self.call_rt("__rt_str_upper", &[text], true),
            "lower" => self.call_rt("__rt_str_lower", &[text], true),
            "trim" => self.call_rt("__rt_str_trim", &[text], true),
            "contains" => self.call_rt("__rt_str_contains", &[text, Arg::Borrow(&args[0])], true),
            "starts_with" => self.call_rt("__rt_str_starts", &[text, Arg::Borrow(&args[0])], true),
            "ends_with" => self.call_rt("__rt_str_ends", &[text, Arg::Borrow(&args[0])], true),
            "index_of" => self.call_rt("__rt_str_index_of", &[text, Arg::Borrow(&args[0])], true),
            "slice" => self.call_rt("__rt_str_slice", &[text, Arg::Value(&args[0]), Arg::Value(&args[1])], true),
            "replace" => {
                self.call_rt("__rt_str_replace", &[text, Arg::Borrow(&args[0]), Arg::Borrow(&args[1])], true)
            }
            "split" => self.call_rt("__rt_str_split", &[text, Arg::Borrow(&args[0]), strings], true),
            "chars" => self.call_rt("__rt_str_chars", &[text, strings], true),
            "repeat" => self.call_rt("__rt_str_repeat", &[text, Arg::Value(&args[0])], true),
            _ => self.unsupported(e.span, &format!("calls to the string method `{name}`")),
        }
    }

    /// `for c in text`: one character per turn. The loop keeps a position in
    /// bytes, so that a text of any length is walked in a single pass.
    fn for_str(&mut self, var: &str, var_span: Span, iter: &Expr, body: &Block) {
        let (top, next, check, end) =
            (self.asm.new_label(), self.asm.new_label(), self.asm.new_label(), self.asm.new_label());
        // Outer scope: the string (kept alive for the whole loop) and the position in it.
        self.scopes.push(Vec::new());
        self.expr(iter);
        let text = self.declare("<string>", (var_span.start, SUBJECT), &Type::Str);
        self.store_loc(text, RAX);
        let position = self.home((var_span.start, COUNTER));
        self.asm.mov_imm(RAX, 0);
        self.store_loc(position, RAX);
        self.asm.jmp(check);

        self.asm.bind(top);
        self.load_loc(RAX, text);
        self.asm.push(RAX);
        self.load_loc(RAX, position);
        self.asm.push(RAX);
        self.call_runtime("__rt_char_at", 2);
        // The next turn starts after this character, however many bytes it takes.
        self.asm.load32(RCX, RAX, 8);
        self.load_loc(RDX, position);
        self.asm.alu(Alu::Add, RDX, RCX);
        self.store_loc(position, RDX);

        // Inner scope: the loop variable, released after each turn.
        self.scopes.push(Vec::new());
        let item = self.declare(var, (var_span.start, NAMED), &Type::Str);
        self.store_loc(item, RAX);
        let depth = self.scopes.len();
        self.loops.push(Loop { next, end, continue_from: depth, break_from: depth - 1 });
        self.block(body);
        self.loops.pop();

        self.asm.bind(next);
        self.release_scopes(depth - 1);
        self.scopes.pop();
        self.asm.bind(check);
        self.load_loc(RCX, text);
        self.asm.load32(RCX, RCX, 8);
        self.load_loc(RAX, position);
        self.asm.alu(Alu::Cmp, RAX, RCX);
        self.asm.jcc(Cc::L, top);

        self.asm.bind(end);
        self.release_scopes(self.scopes.len() - 1);
        self.scopes.pop();
    }

    fn list_method(&mut self, e: &Expr, obj: &Expr, name: &str, args: &[Expr]) {
        // An element given to the list (moved into it) or only shown to it.
        let element = |g: &Self, arg: &'_ Expr, moved: bool| -> u8 {
            match (is_ref(&g.ty(arg)), moved) {
                (false, _) => 0,
                (true, true) => 1,
                (true, false) => 2,
            }
        };
        let make = |kind: u8, arg| match kind {
            0 => Arg::Value(arg),
            1 => Arg::Move(arg),
            _ => Arg::Borrow(arg),
        };
        match name {
            "len" => {
                if self.is_place(obj) {
                    self.place(obj);
                    self.asm.load(RAX, RAX, LIST_LEN);
                } else {
                    let owned = self.operand(obj);
                    if owned {
                        self.asm.push(RAX);
                    }
                    self.asm.load(RAX, RAX, LIST_LEN);
                    if owned {
                        self.release_saved();
                    }
                }
            }
            "push" => {
                if let Some(list) = self.local(obj) {
                    // The list is in a variable: when it has room, the value
                    // is stored right here. It moves into the list.
                    self.expr(&args[0]);
                    self.load_loc(RCX, list.loc);
                    self.asm.load(RDX, RCX, LIST_LEN);
                    self.asm.alu_load(Alu::Cmp, RDX, RCX, LIST_CAP);
                    let full = self.asm.jcc_short(Cc::E);
                    self.asm.load(R8, RCX, LIST_DATA);
                    self.asm.store_indexed(R8, RDX, RAX);
                    self.asm.alu_imm(Alu::Add, RDX, 1);
                    self.asm.store(RCX, LIST_LEN, RDX);
                    let done = self.asm.jmp_short();
                    self.asm.bind_short(full);
                    self.asm.push(RCX);
                    self.asm.push(RAX);
                    self.call_runtime("__rt_list_push", 2);
                    self.asm.bind_short(done);
                    return;
                }
                let kind = element(self, &args[0], true);
                self.call_rt("__rt_list_push", &[Arg::Borrow(obj), make(kind, &args[0])], false);
            }
            "insert" => {
                let kind = element(self, &args[1], true);
                self.call_rt("__rt_list_insert", &[Arg::Borrow(obj), Arg::Value(&args[0]), make(kind, &args[1])], false);
            }
            "remove" => self.call_rt("__rt_list_remove", &[Arg::Borrow(obj), Arg::Value(&args[0])], true),
            "pop" => self.call_rt_fallible("__rt_list_pop", &[Arg::Borrow(obj)], true),
            "first" => self.call_rt_fallible("__rt_list_first", &[Arg::Borrow(obj)], true),
            "last" => self.call_rt_fallible("__rt_list_last", &[Arg::Borrow(obj)], true),
            "clear" => self.call_rt("__rt_list_clear", &[Arg::Borrow(obj)], false),
            "contains" | "index_of" => {
                let kind = element(self, &args[0], false);
                let function = if name == "contains" { "__rt_list_contains" } else { "__rt_list_index_of" };
                self.call_rt(function, &[Arg::Borrow(obj), make(kind, &args[0])], true);
            }
            "slice" => {
                self.call_rt("__rt_list_slice", &[Arg::Borrow(obj), Arg::Value(&args[0]), Arg::Value(&args[1])], true)
            }
            "reverse" => self.call_rt("__rt_list_reverse", &[Arg::Borrow(obj)], true),
            "sort" => self.call_rt("__rt_list_sort", &[Arg::Borrow(obj)], true),
            "join" => self.call_rt("__rt_list_join", &[Arg::Borrow(obj), Arg::Borrow(&args[0])], true),
            "map" | "filter" | "sort_by" => {
                // These run code of the program, the function they are
                // given: nothing may be borrowed from a place it could change.
                let owned = [self.push_arg(obj), self.push_arg(&args[0]), false];
                let extra = match (name, self.ty(&args[0])) {
                    ("map", _) => self.ty(e),
                    (_, Type::Fn(sig)) => sig.ret.clone(),
                    _ => Type::Int,
                };
                let td = self.descriptor(&extra);
                self.asm.lea(RAX, td);
                self.asm.push(RAX);
                self.call_runtime(&format!("__rt_list_{name}"), 0);
                self.drop_args(&owned, true);
            }
            _ => self.unsupported(e.span, &format!("calls to the list method `{name}`")),
        }
    }

    fn builtin(&mut self, name: &str, e: &Expr, args: &[Expr]) {
        match name {
            "print" => {
                // print(a, b) writes "a b" and a line break; interpolated
                // strings are written piece by piece, without being built.
                let mut pieces: Vec<Piece> = Vec::new();
                let text = |pieces: &mut Vec<Piece>, s: &str| match pieces.last_mut() {
                    Some(Piece::Text(previous)) => previous.push_str(s),
                    _ if s.is_empty() => {}
                    _ => pieces.push(Piece::Text(s.to_string())),
                };
                for (i, arg) in args.iter().enumerate() {
                    if i > 0 {
                        text(&mut pieces, " ");
                    }
                    match &arg.kind {
                        ExprKind::Str(parts) => {
                            for part in parts {
                                match part {
                                    StrPart::Lit(s) => text(&mut pieces, s),
                                    StrPart::Expr(inner) => pieces.push(Piece::Expr(inner)),
                                }
                            }
                        }
                        _ => pieces.push(Piece::Expr(arg)),
                    }
                }
                let pushed = self.push_pieces(&pieces);
                self.asm.mov(RAX, RSP);
                self.asm.push(RAX);
                self.asm.push_imm(pieces.len() as i32);
                self.call_runtime("__rt_print_pieces", 2);
                self.drop_pieces(pushed, false);
            }
            "str" => {
                if self.ty(&args[0]) == Type::Str {
                    self.expr(&args[0]);
                } else {
                    self.to_str(&args[0]);
                }
            }
            "parse_int" => self.call_rt_fallible("__rt_parse_int", &[Arg::Borrow(&args[0])], true),
            "exit" => self.call_rt("__rt_exit", &[Arg::Value(&args[0])], false),
            "panic" => self.call_rt("__rt_panic", &[Arg::Borrow(&args[0])], false),
            "float" => {
                self.float(e);
                self.asm.movq_out(RAX, XMM0);
            }
            "int" if self.ty(&args[0]) == Type::Float => {
                self.float(&args[0]);
                self.asm.cvttsd2si(RAX, XMM0);
            }
            "int" => self.expr(&args[0]),
            "sqrt" => {
                self.float(e);
                self.asm.movq_out(RAX, XMM0);
            }
            "pow" => self.call_rt("__rt_pow", &[Arg::Value(&args[0]), Arg::Value(&args[1])], true),
            "floor" => self.call_rt("__rt_floor", &[Arg::Value(&args[0])], true),
            "ceil" => self.call_rt("__rt_ceil", &[Arg::Value(&args[0])], true),
            "round" => self.call_rt("__rt_round_float", &[Arg::Value(&args[0])], true),
            "parse_float" => self.call_rt_fallible("__rt_parse_float", &[Arg::Borrow(&args[0])], true),
            "random" => self.call_rt("__rt_random", &[], true),
            "random_int" => self.call_rt("__rt_random_int", &[Arg::Value(&args[0]), Arg::Value(&args[1])], true),
            "abs" if self.ty(e) == Type::Float => {
                // Clear the sign bit.
                self.expr(&args[0]);
                self.asm.shift(Shift::Left, RAX, 1);
                self.asm.shift(Shift::Right, RAX, 1);
            }
            "min" | "max" if self.ty(e) == Type::Float => {
                let function = if name == "min" { "__rt_float_min" } else { "__rt_float_max" };
                self.call_rt(function, &[Arg::Value(&args[0]), Arg::Value(&args[1])], true);
            }
            "abs" => {
                self.expr(&args[0]);
                self.asm.alu_imm(Alu::Cmp, RAX, 0);
                let positive = self.asm.jcc_short(Cc::Ge);
                self.asm.neg(RAX);
                self.asm.bind_short(positive);
            }
            "min" | "max" => {
                let keep = if name == "min" { Cc::Le } else { Cc::Ge };
                match self.simple(&args[1]) {
                    Some(other) => {
                        self.expr(&args[0]);
                        self.operand_alu(Alu::Cmp, RAX, other);
                        let done = self.asm.jcc_short(keep);
                        self.load_operand(RAX, other);
                        self.asm.bind_short(done);
                    }
                    None => {
                        self.expr(&args[0]);
                        self.asm.push(RAX);
                        self.expr(&args[1]);
                        self.asm.mov(RCX, RAX);
                        self.asm.pop(RAX);
                        self.asm.alu(Alu::Cmp, RAX, RCX);
                        let done = self.asm.jcc_short(keep);
                        self.asm.mov(RAX, RCX);
                        self.asm.bind_short(done);
                    }
                }
            }

            // ---- low-level operations reserved to the runtime ----
            "__syscall" => {
                // RSI and RDI carry arguments but may hold variables: keep them.
                self.asm.push(RSI);
                self.asm.push(RDI);
                for arg in args {
                    self.push_value(arg);
                }
                for reg in [R9, R8, R10, RDX, RSI, RDI, RAX] {
                    self.asm.pop(reg);
                }
                self.asm.syscall();
                self.asm.pop(RDI);
                self.asm.pop(RSI);
            }
            "__load8" | "__load32" | "__load64" => {
                let (base, offset) = self.address(&args[0]);
                match name {
                    "__load8" => self.asm.load8(RAX, base, offset),
                    "__load32" => self.asm.load32(RAX, base, offset),
                    _ => self.asm.load(RAX, base, offset),
                }
            }
            "__store8" | "__store32" | "__store64" => {
                let (base, offset, source) = match self.simple(&args[1]) {
                    Some(Operand::Imm(v)) if name == "__store64" => {
                        let (base, offset) = self.address(&args[0]);
                        self.asm.store_imm(base, offset, v as i32);
                        return;
                    }
                    Some(operand) => {
                        let (base, offset) = self.address(&args[0]);
                        match operand {
                            Operand::At(Loc::Reg(r)) => (base, offset, r),
                            other => {
                                self.load_operand(RCX, other);
                                (base, offset, RCX)
                            }
                        }
                    }
                    None => match self.address(&args[0]) {
                        // The address had to be computed: it waits on the stack.
                        (RAX, offset) => {
                            self.asm.push(RAX);
                            self.expr(&args[1]);
                            self.asm.pop(RCX);
                            (RCX, offset, RAX)
                        }
                        (base, offset) => {
                            self.expr(&args[1]);
                            (base, offset, RAX)
                        }
                    },
                };
                match name {
                    "__store8" => self.asm.store8(base, offset, source),
                    "__store32" => self.asm.store32(base, offset, source),
                    _ => self.asm.store(base, offset, source),
                }
            }
            "__copy" => {
                self.push_value(&args[0]);
                self.push_value(&args[1]);
                match self.simple(&args[2]) {
                    Some(count) => self.load_operand(RCX, count),
                    None => {
                        self.expr(&args[2]);
                        self.asm.mov(RCX, RAX);
                    }
                }
                // RSI and RDI may hold variables: they are kept in RAX and RDX.
                self.asm.mov(RAX, RSI);
                self.asm.mov(RDX, RDI);
                self.asm.pop(RSI);
                self.asm.pop(RDI);
                self.copy_bytes();
                self.asm.mov(RSI, RAX);
                self.asm.mov(RDI, RDX);
            }
            "__and" => {
                self.expr(&args[0]);
                match self.simple(&args[1]) {
                    Some(operand) => self.operand_alu(Alu::And, RAX, operand),
                    None => {
                        self.asm.push(RAX);
                        self.expr(&args[1]);
                        self.asm.pop(RCX);
                        self.asm.alu(Alu::And, RAX, RCX);
                    }
                }
            }
            "__or" | "__xor" => {
                let alu = if name == "__or" { Alu::Or } else { Alu::Xor };
                self.expr(&args[0]);
                self.asm.push(RAX);
                self.expr(&args[1]);
                self.asm.pop(RCX);
                self.asm.alu(alu, RAX, RCX);
            }
            "__shl" | "__shr" | "__sar" => {
                let kind = match name {
                    "__shl" => Shift::Left,
                    "__shr" => Shift::Right,
                    _ => Shift::RightSigned,
                };
                match &args[1].kind {
                    ExprKind::Int(count) => {
                        self.expr(&args[0]);
                        self.asm.shift(kind, RAX, *count as u8);
                    }
                    _ => {
                        self.expr(&args[0]);
                        self.asm.push(RAX);
                        self.expr(&args[1]);
                        self.asm.mov(RCX, RAX);
                        self.asm.pop(RAX);
                        self.asm.shift_cl(kind, RAX);
                    }
                }
            }
            // A float and its bits are the same 64 bits: only the type changes.
            "__bits" | "__float" => self.expr(&args[0]),
            "__call1" => {
                // Calls a closure with one argument.
                self.expr(&args[0]);
                self.asm.push(RAX);
                self.expr(&args[1]);
                self.asm.push(RAX);
                self.asm.load(R10, RSP, 8);
                self.asm.call_mem(R10, FIELDS);
                self.asm.alu_imm(Alu::Add, RSP, 16);
            }
            "__state" => self.asm.mov(RAX, R15),
            "__td_string" => {
                let td = self.descriptor(&Type::Str);
                self.asm.lea(RAX, td);
            }
            // The address of a string, without taking a reference.
            "__str_ptr" => {
                if self.local(&args[0]).is_none() {
                    self.unsupported(e.span, "`__str_ptr` on anything but a local variable");
                }
                self.operand(&args[0]);
            }
            // An address the runtime owns becomes an owned string.
            "__ptr_str" => self.expr(&args[0]),
            other => self.unsupported(e.span, &format!("calls to `{other}`")),
        }
    }

    /// Copies RCX bytes from [RSI] to [RDI]; R8 and R9 are scratch. Most
    /// copies are a few bytes long (short strings), so those are done with
    /// two possibly overlapping moves: the first and the last 8 (or 4) bytes.
    /// Both are read before anything is written, so the areas may overlap.
    fn copy_bytes(&mut self) {
        self.asm.alu_imm(Alu::Cmp, RCX, 16);
        let long = self.asm.jcc_short(Cc::G);
        self.asm.alu_imm(Alu::Cmp, RCX, 8);
        let under_8 = self.asm.jcc_short(Cc::L);
        self.asm.load(R8, RSI, 0);
        self.asm.load_at(R9, RSI, RCX, -8, true);
        self.asm.store(RDI, 0, R8);
        self.asm.store_at(RDI, RCX, -8, R9, true);
        let done_8 = self.asm.jmp_short();

        self.asm.bind_short(under_8);
        self.asm.alu_imm(Alu::Cmp, RCX, 4);
        let under_4 = self.asm.jcc_short(Cc::L);
        self.asm.load32(R8, RSI, 0);
        self.asm.load_at(R9, RSI, RCX, -4, false);
        self.asm.store32(RDI, 0, R8);
        self.asm.store_at(RDI, RCX, -4, R9, false);
        let done_4 = self.asm.jmp_short();

        self.asm.bind_short(under_4);
        self.asm.test(RCX, RCX);
        let done_0 = self.asm.jcc_short(Cc::E);
        let next = self.asm.pos();
        self.asm.load8(R8, RSI, 0);
        self.asm.store8(RDI, 0, R8);
        self.asm.alu_imm(Alu::Add, RSI, 1);
        self.asm.alu_imm(Alu::Add, RDI, 1);
        self.asm.alu_imm(Alu::Sub, RCX, 1);
        self.asm.jcc_back(Cc::Ne, next);
        let done_bytes = self.asm.jmp_short();

        self.asm.bind_short(long);
        self.asm.rep_movsb();
        self.asm.bind_short(done_8);
        self.asm.bind_short(done_4);
        self.asm.bind_short(done_0);
        self.asm.bind_short(done_bytes);
    }

    /// Prepares the address `e` for a memory access: returns the register
    /// that holds its base and the constant to add. `p + 8` with `p` in a
    /// register needs no instruction at all.
    fn address(&mut self, e: &Expr) -> (Reg, i32) {
        let (base, offset) = match &e.kind {
            ExprKind::Binary { op: BinOp::Add, lhs, rhs } => match rhs.kind {
                ExprKind::Int(k) if i32::try_from(k).is_ok() => (&**lhs, k as i32),
                _ => (e, 0),
            },
            _ => (e, 0),
        };
        if let Some(Operand::At(Loc::Reg(r))) = self.simple(base) {
            return (r, offset);
        }
        self.expr(base);
        (RAX, offset)
    }
}

#[cfg(test)]
mod tests {
    use super::magic_number;

    /// What the generated code computes for `n / d`.
    fn divide_with_magic(n: i64, d: i64) -> i64 {
        let (magic, shift) = magic_number(d);
        let mut high = ((magic as i128 * n as i128) >> 64) as i64;
        if d > 0 && magic < 0 {
            high = high.wrapping_add(n);
        }
        if d < 0 && magic > 0 {
            high = high.wrapping_sub(n);
        }
        high >>= shift;
        high.wrapping_add(((high as u64) >> 63) as i64)
    }

    #[test]
    fn magic_division_matches_real_division() {
        let divisors: Vec<i64> = (3..=300)
            .chain([641, 1000, 1001, 4095, 4097, 65535, 99999, 1_000_003, 123_456_789, i32::MAX as i64])
            .flat_map(|d| [d, -d])
            .filter(|d: &i64| !d.unsigned_abs().is_power_of_two())
            .collect();
        // A simple generator is enough: the edge cases are listed by hand.
        let mut seed: u64 = 0x9E37_79B9_7F4A_7C15;
        let mut values = vec![0, 1, -1, 2, -2, 9, -9, 10, -10, 99, 100, 101, i64::MAX, i64::MIN, i64::MAX - 1, i64::MIN + 1];
        for _ in 0..2000 {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            values.push(seed as i64);
            values.push((seed >> 40) as i64 - (1 << 23));
        }
        for &d in &divisors {
            for &n in &values {
                assert_eq!(divide_with_magic(n, d), n.wrapping_div(d), "{n} / {d}");
            }
        }
    }
}
