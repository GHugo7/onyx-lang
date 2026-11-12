//! Native backend: AST + analysis -> x86-64 machine code in a Linux executable.
//!
//! VALUES. Every value is 64 bits wide: an integer, a boolean, or the address
//! of a heap object (string, list, struct). Object layouts and type
//! descriptors are documented at the top of `runtime.ox`.
//!
//! CODE SHAPE. The generated code is a simple stack machine. An expression
//! leaves its result in RAX; intermediate values are pushed on the stack.
//!
//! CALLS (a convention private to Onyx). The caller pushes the arguments from
//! first to last, calls, then removes them; the result comes back in RAX and
//! every other register may have changed. Inside a function RBP points to the
//! frame: parameters are above it, local variables below. R15 always holds
//! the address of the runtime's state, which is followed by the program's
//! top-level variables.
//!
//! MEMORY. References are counted. The rules the generator follows:
//!   - evaluating an expression yields an *owned* reference: whoever asked for
//!     it must store it somewhere, pass it on, or release it;
//!   - a variable, a field and a list slot each own what they hold;
//!   - a function owns its parameters and releases them when it returns;
//!   - leaving a scope releases the variables declared in it.

mod asm;
mod elf;

use crate::ast::*;
use crate::checker::{method_key, Analysis, CallKind, Recv, Type};
use crate::diagnostics::{Diagnostic, Span};
use asm::*;
use std::collections::HashMap;

/// The runtime, written in Onyx and compiled into every native program.
pub const RUNTIME_SOURCE: &str = include_str!("runtime.ox");

/// Size of the runtime's state; top-level variables are stored right after it.
const STATE_SIZE: i32 = 4096;

// Offsets inside heap objects (see runtime.ox).
const LIST_LEN: i32 = 16;
const LIST_DATA: i32 = 32;
const FIELDS: i32 = 16;

pub fn generate(program: &Program, an: &Analysis, leak_check: bool) -> Result<Vec<u8>, Vec<Diagnostic>> {
    let mut g = Gen {
        an,
        asm: Asm::default(),
        diags: Vec::new(),
        fns: HashMap::new(),
        globals: HashMap::new(),
        strings: HashMap::new(),
        descriptors: HashMap::new(),
        pending_descriptors: Vec::new(),
        scopes: Vec::new(),
        slots: 0,
        loops: Vec::new(),
        epilogue: None,
    };

    // Labels for every function, storage for every top-level variable.
    let mut global_order = Vec::new();
    for item in &program.items {
        match item {
            Item::Fn(f) => {
                let label = g.asm.new_label();
                g.fns.insert(f.name.clone(), label);
            }
            Item::Struct(s) => {
                for m in &s.methods {
                    let label = g.asm.new_label();
                    g.fns.insert(method_key(&s.name, &m.name), label);
                }
                let fields = an.structs[&s.name].fields.clone();
                for (decl, (_, ty)) in s.fields.iter().zip(&fields) {
                    g.check_type(ty, decl.ty.span);
                }
            }
            Item::Global(Stmt { kind: StmtKind::Let { name, init, .. }, .. }) => {
                let ty = g.ty(init);
                let offset = STATE_SIZE + 8 * global_order.len() as i32;
                g.globals.insert(name.clone(), (offset, ty));
                global_order.push(name.clone());
            }
            _ => {}
        }
    }

    // Program entry: map the state, initialise the top-level variables, run main.
    let entry = g.asm.pos();
    let state_bytes = (STATE_SIZE as i64 + 8 * global_order.len() as i64 + 4095) / 4096 * 4096;
    for (reg, value) in [(RAX, 9), (RDI, 0), (RSI, state_bytes), (RDX, 3), (R10, 0x22), (R8, -1), (R9, 0)] {
        g.asm.mov_imm(reg, value); // mmap(NULL, size, READ | WRITE, PRIVATE | ANONYMOUS, -1, 0)
    }
    g.asm.syscall();
    g.asm.mov(R15, RAX);
    g.asm.mov(RBP, RSP);
    for item in &program.items {
        if let Item::Global(Stmt { kind: StmtKind::Let { name, init, .. }, .. }) = item {
            g.expr(init);
            let offset = g.globals[name].0;
            g.asm.store(R15, offset, RAX);
        }
    }
    if let Some(&main) = g.fns.get("main") {
        g.asm.call(main);
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
    g.asm.mov_imm(RDI, 0);
    g.asm.mov_imm(RAX, 231); // exit_group
    g.asm.syscall();

    for item in &program.items {
        match item {
            Item::Fn(f) => {
                if let Some(sig) = an.fns.get(&f.name) {
                    let params = f.params.iter().map(|p| p.name.clone()).zip(sig.params.iter().cloned()).collect();
                    g.function(f, &f.name, params, &sig.ret);
                }
            }
            Item::Struct(s) => {
                for m in &s.methods {
                    let sig = an.structs[&s.name].methods[&m.name].clone();
                    let mut params = vec![("self".to_string(), Type::Struct(s.name.clone()))];
                    params.extend(m.params.iter().map(|p| p.name.clone()).zip(sig.params.iter().cloned()));
                    g.function(m, &method_key(&s.name, &m.name), params, &sig.ret);
                }
            }
            _ => {}
        }
    }

    g.emit_constants();

    if !g.diags.is_empty() {
        g.diags.sort_by_key(|d| d.span.start);
        g.diags.dedup_by_key(|d| (d.span.start, d.message.clone()));
        return Err(g.diags);
    }
    Ok(elf::write(&g.asm.finish(elf::IMAGE_BASE), entry))
}

fn is_ref(ty: &Type) -> bool {
    matches!(ty, Type::Str | Type::List(_) | Type::Struct(_) | Type::Interface(_))
}

fn supported(ty: &Type) -> bool {
    match ty {
        Type::Int | Type::Bool | Type::Str | Type::Void | Type::Range | Type::Unknown => true,
        Type::Struct(_) | Type::Interface(_) => true,
        Type::List(elem) => supported(elem),
        _ => false,
    }
}

/// Where a variable lives.
#[derive(Clone, Copy)]
enum Place {
    /// Offset from RBP: a parameter or a local variable.
    Frame(i32),
    /// Offset from R15: a top-level variable.
    Global(i32),
}

struct Var {
    name: String,
    offset: i32,
    is_ref: bool,
}

struct Loop {
    next: Label,
    end: Label,
    /// `continue` / `break` release the variables of the scopes from this index on.
    continue_from: usize,
    break_from: usize,
}

struct Gen<'a> {
    an: &'a Analysis,
    asm: Asm,
    diags: Vec<Diagnostic>,
    /// Function name (or method key) -> its code.
    fns: HashMap<String, Label>,
    /// Top-level variable -> (offset from R15, type).
    globals: HashMap<String, (i32, Type)>,
    strings: HashMap<Vec<u8>, Label>,
    /// Type (by its display name) -> its descriptor table.
    descriptors: HashMap<String, Label>,
    pending_descriptors: Vec<(Type, Label)>,
    /// Local variables, innermost scope last.
    scopes: Vec<Vec<Var>>,
    /// Local slots used so far by the current function.
    slots: i32,
    loops: Vec<Loop>,
    epilogue: Option<Label>,
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

    // ---- constants ----

    fn string(&mut self, text: &str) -> Label {
        if let Some(&label) = self.strings.get(text.as_bytes()) {
            return label;
        }
        let label = self.asm.new_label();
        self.strings.insert(text.as_bytes().to_vec(), label);
        label
    }

    /// The descriptor table of a type; it is written out by `emit_constants`.
    fn descriptor(&mut self, ty: &Type) -> Label {
        let key = ty.to_string();
        if let Some(&label) = self.descriptors.get(&key) {
            return label;
        }
        let label = self.asm.new_label();
        self.descriptors.insert(key, label);
        self.pending_descriptors.push((ty.clone(), label));
        label
    }

    fn emit_constants(&mut self) {
        let string_td = self.descriptor(&Type::Str);
        while let Some((ty, label)) = self.pending_descriptors.pop() {
            self.asm.align(8);
            match &ty {
                Type::List(elem) => {
                    let elem = self.descriptor(elem);
                    self.asm.bind(label);
                    self.asm.word(4);
                    self.asm.address(elem);
                }
                Type::Struct(name) => {
                    let info = self.an.structs[name].clone();
                    let name_label = self.string(name);
                    let fields: Vec<(Label, Label)> =
                        info.fields.iter().map(|(n, t)| (self.string(n), self.descriptor(t))).collect();
                    let mut names: Vec<&String> = info.methods.keys().collect();
                    names.sort();
                    let methods: Vec<(Label, Label)> =
                        names.iter().map(|m| (self.string(m), self.fns[&method_key(name, m)])).collect();
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
                        Type::Int => 0,
                        Type::Bool => 1,
                        Type::Str => 3,
                        Type::Interface(_) => 6,
                        _ => 0,
                    };
                    self.asm.bind(label);
                    self.asm.word(kind);
                }
            }
        }
        // String constants: a header marking them as never released, then the text.
        let mut strings: Vec<(Vec<u8>, Label)> = self.strings.iter().map(|(s, l)| (s.clone(), *l)).collect();
        strings.sort_by(|a, b| a.0.cmp(&b.0));
        for (text, label) in strings {
            self.asm.align(8);
            self.asm.bind(label);
            self.asm.word(-1i64 as u64);
            self.asm.address(string_td);
            self.asm.word(text.len() as u64);
            self.asm.bytes(&text);
        }
    }

    // ---- reference counting ----

    /// Adds one reference to the object in RAX (keeps RAX, changes RCX).
    fn retain_rax(&mut self) {
        let skip = self.asm.new_label();
        self.asm.load(RCX, RAX, 0);
        self.asm.alu_imm(AluImm::Cmp, RCX, 0);
        self.asm.jcc(Cc::L, skip); // a constant: its count never changes
        self.asm.alu_imm(AluImm::Add, RCX, 1);
        self.asm.store(RAX, 0, RCX);
        self.asm.bind(skip);
    }

    /// Drops one reference to the object in RAX. Every register may change.
    fn release_rax(&mut self) {
        self.asm.push(RAX);
        self.call_runtime("__rt_release", 1);
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

    /// Releases the variables of the scopes from `first` on (they stay declared).
    fn release_scopes(&mut self, first: usize) {
        let offsets: Vec<i32> =
            self.scopes[first..].iter().rev().flat_map(|s| s.iter().rev()).filter(|v| v.is_ref).map(|v| v.offset).collect();
        for offset in offsets {
            self.asm.load(RAX, RBP, offset);
            self.release_rax();
        }
    }

    fn holds_refs(&self, first: usize) -> bool {
        self.scopes[first..].iter().any(|s| s.iter().any(|v| v.is_ref))
    }

    // ---- functions ----

    fn function(&mut self, f: &FnDecl, key: &str, params: Vec<(String, Type)>, ret: &Type) {
        for (i, (_, ty)) in params.iter().enumerate() {
            let span = if f.has_self && i == 0 { f.name_span } else { f.params[i - f.has_self as usize].ty.span };
            self.check_type(ty, span);
        }
        self.check_type(ret, f.ret.as_ref().map(|t| t.span).unwrap_or(f.name_span));
        if f.fallible {
            self.unsupported(f.name_span, "functions that can fail (`!`)");
        }

        let label = self.fns[key];
        let epilogue = self.asm.new_label();
        self.epilogue = Some(epilogue);
        self.slots = 0;
        // The first argument was pushed first, so it is the farthest from RBP.
        let count = params.len() as i32;
        self.scopes = vec![params
            .into_iter()
            .enumerate()
            .map(|(i, (name, ty))| Var { name, offset: 16 + 8 * (count - 1 - i as i32), is_ref: is_ref(&ty) })
            .collect()];

        self.asm.bind(label);
        self.asm.push(RBP);
        self.asm.mov(RBP, RSP);
        self.asm.alu_imm(AluImm::Sub, RSP, 0);
        let frame_size_at = self.asm.pos() - 4;

        for stmt in &f.body.stmts {
            self.stmt(stmt);
        }

        self.release_scopes(0);
        self.asm.mov_imm(RAX, 0);
        self.asm.bind(epilogue);
        self.asm.mov(RSP, RBP);
        self.asm.pop(RBP);
        self.asm.ret();
        self.asm.patch32(frame_size_at, self.slots * 8);
        self.scopes.clear();
    }

    fn new_slot(&mut self) -> i32 {
        self.slots += 1;
        -8 * self.slots
    }

    fn declare(&mut self, name: &str, ty: &Type) -> i32 {
        let offset = self.new_slot();
        self.scopes.last_mut().unwrap().push(Var { name: name.to_string(), offset, is_ref: is_ref(ty) });
        offset
    }

    fn lookup(&self, name: &str) -> Option<Place> {
        for scope in self.scopes.iter().rev() {
            if let Some(var) = scope.iter().rev().find(|v| v.name == name) {
                return Some(Place::Frame(var.offset));
            }
        }
        self.globals.get(name).map(|(offset, _)| Place::Global(*offset))
    }

    fn is_local(&self, e: &Expr) -> bool {
        matches!(&e.kind, ExprKind::Ident(name) if matches!(self.lookup(name), Some(Place::Frame(_))))
    }

    fn load_place(&mut self, dst: Reg, place: Place) {
        match place {
            Place::Frame(offset) => self.asm.load(dst, RBP, offset),
            Place::Global(offset) => self.asm.load(dst, R15, offset),
        }
    }

    fn store_place(&mut self, place: Place, src: Reg) {
        match place {
            Place::Frame(offset) => self.asm.store(RBP, offset, src),
            Place::Global(offset) => self.asm.store(R15, offset, src),
        }
    }

    // ---- statements ----

    fn block(&mut self, block: &Block) {
        self.scopes.push(Vec::new());
        for stmt in &block.stmts {
            self.stmt(stmt);
        }
        self.release_scopes(self.scopes.len() - 1);
        self.scopes.pop();
    }

    fn stmt(&mut self, stmt: &Stmt) {
        match &stmt.kind {
            StmtKind::Let { name, init, .. } => {
                self.expr(init);
                let offset = self.declare(name, &self.ty(init));
                self.asm.store(RBP, offset, RAX);
            }
            StmtKind::Assign { target, op, value } => self.assign(target, *op, value),
            StmtKind::Expr(e) => {
                self.expr(e);
                if is_ref(&self.ty(e)) {
                    self.release_rax();
                }
            }
            StmtKind::If { cond, then, els } => {
                let otherwise = self.asm.new_label();
                let end = self.asm.new_label();
                self.expr(cond);
                self.asm.alu(Alu::Test, RAX, RAX);
                self.asm.jcc(Cc::E, otherwise);
                self.block(then);
                self.asm.jmp(end);
                self.asm.bind(otherwise);
                if let Some(els) = els {
                    self.stmt(els);
                }
                self.asm.bind(end);
            }
            StmtKind::While { cond, body } => {
                let top = self.asm.new_label();
                let end = self.asm.new_label();
                self.asm.bind(top);
                self.expr(cond);
                self.asm.alu(Alu::Test, RAX, RAX);
                self.asm.jcc(Cc::E, end);
                let depth = self.scopes.len();
                self.loops.push(Loop { next: top, end, continue_from: depth, break_from: depth });
                self.block(body);
                self.loops.pop();
                self.asm.jmp(top);
                self.asm.bind(end);
            }
            StmtKind::For { var, iter, body, .. } => match self.ty(iter) {
                Type::Range => self.for_range(var, iter, body),
                Type::List(elem) => self.for_list(var, iter, body, &elem),
                _ => self.unsupported(iter.span, "loops over strings, maps and channels"),
            },
            StmtKind::Return(value) => {
                if let Some(v) = value {
                    self.expr(v);
                } else {
                    self.asm.mov_imm(RAX, 0);
                }
                if self.holds_refs(0) {
                    self.asm.push(RAX);
                    self.release_scopes(0);
                    self.asm.pop(RAX);
                }
                let epilogue = self.epilogue.unwrap();
                self.asm.jmp(epilogue);
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
            StmtKind::Fail(_) => self.unsupported(stmt.span, "`fail` statements"),
            StmtKind::Fork(_) => self.unsupported(stmt.span, "`fork` blocks"),
            StmtKind::Send { .. } => self.unsupported(stmt.span, "channels"),
        }
    }

    fn for_range(&mut self, var: &str, iter: &Expr, body: &Block) {
        let ExprKind::Range { lo, hi } = &iter.kind else {
            self.unsupported(iter.span, "ranges stored in variables");
            return;
        };
        let (top, next, end) = (self.asm.new_label(), self.asm.new_label(), self.asm.new_label());
        self.scopes.push(Vec::new());
        self.expr(lo);
        let counter = self.declare(var, &Type::Int);
        self.asm.store(RBP, counter, RAX);
        self.expr(hi);
        let limit = self.new_slot();
        self.asm.store(RBP, limit, RAX);

        self.asm.bind(top);
        self.asm.load(RAX, RBP, counter);
        self.asm.load(RCX, RBP, limit);
        self.asm.alu(Alu::Cmp, RAX, RCX);
        self.asm.jcc(Cc::Ge, end);
        let depth = self.scopes.len();
        self.loops.push(Loop { next, end, continue_from: depth, break_from: depth });
        self.block(body);
        self.loops.pop();
        self.asm.bind(next);
        self.asm.load(RAX, RBP, counter);
        self.asm.alu_imm(AluImm::Add, RAX, 1);
        self.asm.store(RBP, counter, RAX);
        self.asm.jmp(top);
        self.asm.bind(end);
        self.scopes.pop();
    }

    fn for_list(&mut self, var: &str, iter: &Expr, body: &Block, elem: &Type) {
        let (top, next, end) = (self.asm.new_label(), self.asm.new_label(), self.asm.new_label());
        // Outer scope: the list being walked (kept alive for the whole loop) and the position.
        self.scopes.push(Vec::new());
        self.expr(iter);
        let list = self.declare("<list>", &self.ty(iter));
        self.asm.store(RBP, list, RAX);
        let index = self.new_slot();
        self.asm.mov_imm(RAX, 0);
        self.asm.store(RBP, index, RAX);

        self.asm.bind(top);
        // The length is read again on every turn, so the body may change the list.
        self.asm.load(RCX, RBP, list);
        self.asm.load(RCX, RCX, LIST_LEN);
        self.asm.load(RAX, RBP, index);
        self.asm.alu(Alu::Cmp, RAX, RCX);
        self.asm.jcc(Cc::Ge, end);

        // Inner scope: the loop variable, released after each turn.
        self.scopes.push(Vec::new());
        self.asm.load(RCX, RBP, list);
        self.asm.load(RCX, RCX, LIST_DATA);
        self.asm.mov_imm(RDX, 8);
        self.asm.imul(RAX, RDX);
        self.asm.alu(Alu::Add, RAX, RCX);
        self.asm.load(RAX, RAX, 0);
        if is_ref(elem) {
            self.retain_rax();
        }
        let item = self.declare(var, elem);
        self.asm.store(RBP, item, RAX);

        let depth = self.scopes.len();
        self.loops.push(Loop { next, end, continue_from: depth, break_from: depth - 1 });
        self.block(body);
        self.loops.pop();

        self.asm.bind(next);
        self.release_scopes(depth - 1);
        self.scopes.pop();
        self.asm.load(RAX, RBP, index);
        self.asm.alu_imm(AluImm::Add, RAX, 1);
        self.asm.store(RBP, index, RAX);
        self.asm.jmp(top);

        self.asm.bind(end);
        self.release_scopes(self.scopes.len() - 1);
        self.scopes.pop();
    }

    fn assign(&mut self, target: &Expr, op: AssignOp, value: &Expr) {
        let target_ty = self.ty(target);
        let bin = match op {
            AssignOp::Set => None,
            AssignOp::Add => Some(BinOp::Add),
            AssignOp::Sub => Some(BinOp::Sub),
            AssignOp::Mul => Some(BinOp::Mul),
            AssignOp::Div => Some(BinOp::Div),
        };
        match &target.kind {
            ExprKind::Ident(name) => {
                let Some(place) = self.lookup(name) else { return };
                // Compute the new value (for `+=` and friends, from the current one).
                if let Some(bin) = bin {
                    self.expr(target);
                    self.asm.push(RAX);
                    self.expr(value);
                    self.asm.mov(RCX, RAX);
                    self.asm.pop(RAX);
                    self.binary_op(bin, &target_ty);
                } else {
                    self.expr(value);
                }
                // Store it, then let go of the value it replaces.
                if is_ref(&target_ty) {
                    self.load_place(RCX, place);
                    self.store_place(place, RAX);
                    self.asm.mov(RAX, RCX);
                    self.release_rax();
                } else {
                    self.store_place(place, RAX);
                }
            }
            ExprKind::Field { obj, name, .. } => {
                let Some(offset) = self.field_offset(obj, name) else {
                    self.unsupported(target.span, "assignments to this kind of field");
                    return;
                };
                let owned = self.operand(obj);
                self.asm.push(RAX);
                if let Some(bin) = bin {
                    self.asm.load(RAX, RAX, offset);
                    if is_ref(&target_ty) {
                        self.retain_rax();
                    }
                    self.asm.push(RAX);
                    self.expr(value);
                    self.asm.mov(RCX, RAX);
                    self.asm.pop(RAX);
                    self.binary_op(bin, &target_ty);
                } else {
                    self.expr(value);
                }
                self.asm.load(RCX, RSP, 0);
                self.asm.load(RDX, RCX, offset);
                self.asm.store(RCX, offset, RAX);
                if is_ref(&target_ty) {
                    self.asm.mov(RAX, RDX);
                    self.release_rax();
                }
                self.asm.pop(RAX);
                if owned {
                    self.release_rax();
                }
            }
            ExprKind::Index { obj, index } => {
                if !matches!(self.ty(obj), Type::List(_)) {
                    self.unsupported(target.span, "assignments to elements of maps and strings");
                    return;
                }
                self.expr(obj);
                self.asm.push(RAX);
                self.expr(index);
                self.asm.push(RAX);
                if let Some(bin) = bin {
                    // Stack: list, index. Read the current element first.
                    self.asm.load(RAX, RSP, 8);
                    self.asm.push(RAX);
                    self.asm.load(RAX, RSP, 8);
                    self.asm.push(RAX);
                    self.call_runtime("__rt_list_get", 2);
                    if is_ref(&target_ty) {
                        self.retain_rax();
                    }
                    self.asm.push(RAX);
                    self.expr(value);
                    self.asm.mov(RCX, RAX);
                    self.asm.pop(RAX);
                    self.binary_op(bin, &target_ty);
                } else {
                    self.expr(value);
                }
                self.asm.push(RAX);
                self.call_runtime("__rt_list_set", 2);
                self.asm.pop(RAX);
                self.release_rax();
            }
            _ => self.unsupported(target.span, "assignments to this kind of expression"),
        }
    }

    // ---- expressions ----

    /// Calls a runtime function whose arguments are already on the stack, and
    /// removes `drop` of them afterwards.
    fn call_runtime(&mut self, name: &str, drop: usize) {
        let label = *self.fns.get(name).unwrap_or_else(|| panic!("missing runtime function {name}"));
        self.asm.call(label);
        if drop > 0 {
            self.asm.alu_imm(AluImm::Add, RSP, 8 * drop as i32);
        }
    }

    /// Evaluates `e` and converts the result to an owned string (in RAX).
    fn to_str(&mut self, e: &Expr) {
        self.expr(e);
        let ty = self.ty(e);
        match ty {
            Type::Str => {}
            Type::Int | Type::Bool => {
                self.asm.push(RAX);
                self.call_runtime(if ty == Type::Int { "__rt_int_str" } else { "__rt_bool_str" }, 1);
            }
            _ => {
                self.asm.push(RAX);
                let td = self.descriptor(&ty);
                self.asm.lea(RAX, td);
                self.asm.push(RAX);
                self.call_runtime("__rt_str_of", 2);
            }
        }
    }

    /// Joins strings: each call of `part` leaves one owned string in RAX.
    fn concat_all(&mut self, count: usize, mut part: impl FnMut(&mut Self, usize)) {
        if count == 0 {
            let empty = self.string("");
            self.asm.lea(RAX, empty);
            return;
        }
        part(self, 0);
        for i in 1..count {
            self.asm.push(RAX);
            part(self, i);
            self.asm.push(RAX);
            self.call_runtime("__rt_concat", 2);
        }
    }

    /// Evaluates `e` to use it right away. A local variable is read without
    /// retaining it; the result says whether the caller got an owned reference.
    fn operand(&mut self, e: &Expr) -> bool {
        if let ExprKind::Ident(name) = &e.kind {
            if let Some(Place::Frame(offset)) = self.lookup(name) {
                self.asm.load(RAX, RBP, offset);
                return false;
            }
        }
        self.expr(e);
        is_ref(&self.ty(e))
    }

    fn field_offset(&self, obj: &Expr, field: &str) -> Option<i32> {
        let Type::Struct(name) = self.ty(obj) else { return None };
        let index = self.an.structs[&name].fields.iter().position(|(n, _)| n == field)?;
        Some(FIELDS + 8 * index as i32)
    }

    fn expr(&mut self, e: &Expr) {
        let ty = self.ty(e);
        if !supported(&ty) {
            self.unsupported(e.span, &format!("values of type `{ty}`"));
            return;
        }
        match &e.kind {
            ExprKind::Int(n) => self.asm.mov_imm(RAX, *n),
            ExprKind::Bool(b) => self.asm.mov_imm(RAX, *b as i64),
            ExprKind::Str(parts) => {
                self.concat_all(parts.len(), |g, i| match &parts[i] {
                    StrPart::Lit(s) => {
                        let label = g.string(s);
                        g.asm.lea(RAX, label);
                    }
                    StrPart::Expr(inner) => g.to_str(inner),
                });
            }
            ExprKind::Ident(name) => match self.lookup(name) {
                Some(place) => {
                    self.load_place(RAX, place);
                    if is_ref(&ty) {
                        self.retain_rax();
                    }
                }
                None => self.unsupported(e.span, "functions used as values"),
            },
            ExprKind::List(items) => {
                let td = self.descriptor(&ty);
                self.asm.lea(RAX, td);
                self.asm.push(RAX);
                self.asm.mov_imm(RAX, items.len() as i64);
                self.asm.push(RAX);
                self.call_runtime("__rt_list_new", 2);
                self.asm.push(RAX);
                for item in items {
                    self.asm.load(RAX, RSP, 0);
                    self.asm.push(RAX);
                    self.expr(item);
                    self.asm.push(RAX);
                    self.call_runtime("__rt_list_push", 2);
                }
                self.asm.pop(RAX);
            }
            ExprKind::StructLit { name, fields, .. } => {
                let order: Vec<String> = self.an.structs[name].fields.iter().map(|(n, _)| n.clone()).collect();
                let td = self.descriptor(&ty);
                self.asm.lea(RAX, td);
                self.asm.push(RAX);
                self.asm.mov_imm(RAX, 8 * order.len() as i64);
                self.asm.push(RAX);
                self.call_runtime("__rt_new", 2);
                self.asm.push(RAX);
                for (i, field) in order.iter().enumerate() {
                    if let Some(init) = fields.iter().find(|f| &f.name == field) {
                        self.expr(&init.value);
                        self.asm.load(RCX, RSP, 0);
                        self.asm.store(RCX, FIELDS + 8 * i as i32, RAX);
                    }
                }
                self.asm.pop(RAX);
            }
            ExprKind::Unary { op, expr } => {
                self.expr(expr);
                match op {
                    UnOp::Neg => self.asm.neg(RAX),
                    UnOp::Not => self.asm.alu_imm(AluImm::Xor, RAX, 1),
                }
            }
            ExprKind::Binary { op: op @ (BinOp::And | BinOp::Or), lhs, rhs } => {
                // Short-circuit: the right side only runs when it can change the result.
                let end = self.asm.new_label();
                self.expr(lhs);
                self.asm.alu(Alu::Test, RAX, RAX);
                self.asm.jcc(if *op == BinOp::And { Cc::E } else { Cc::Ne }, end);
                self.expr(rhs);
                self.asm.bind(end);
            }
            ExprKind::Binary { op, lhs, rhs } => {
                self.expr(lhs);
                self.asm.push(RAX);
                self.expr(rhs);
                self.asm.mov(RCX, RAX);
                self.asm.pop(RAX);
                // Comparing a struct with an interface: let the objects tell their type.
                let (l, r) = (self.ty(lhs), self.ty(rhs));
                let operand_ty = if matches!(r, Type::Interface(_)) { r } else { l };
                self.binary_op(*op, &operand_ty);
            }
            ExprKind::Call { callee, args } => self.call(e, callee, args),
            ExprKind::Field { obj, name, .. } => {
                let Some(offset) = self.field_offset(obj, name) else {
                    self.unsupported(e.span, "fields of this type");
                    return;
                };
                let owned = self.operand(obj);
                if owned {
                    self.asm.push(RAX);
                }
                self.asm.load(RAX, RAX, offset);
                if is_ref(&ty) {
                    self.retain_rax();
                }
                if owned {
                    self.release_saved();
                }
            }
            ExprKind::Index { obj, index } => {
                if !matches!(self.ty(obj), Type::List(_)) {
                    self.unsupported(e.span, "indexing into maps and strings");
                    return;
                }
                // Borrowing the list is safe when evaluating the index cannot touch it.
                let simple_index = matches!(index.kind, ExprKind::Int(_)) || self.is_local(index);
                let owned = if simple_index {
                    self.operand(obj)
                } else {
                    self.expr(obj);
                    true
                };
                self.asm.push(RAX);
                self.expr(index);
                self.asm.push(RAX);
                self.call_runtime("__rt_list_get", 1);
                if is_ref(&ty) {
                    self.retain_rax();
                }
                if owned {
                    self.release_saved();
                } else {
                    self.asm.alu_imm(AluImm::Add, RSP, 8);
                }
            }
            ExprKind::Try(_) | ExprKind::Or { .. } | ExprKind::Catch { .. } => {
                self.unsupported(e.span, "`?`, `or` and `catch`")
            }
            ExprKind::Range { .. } => self.unsupported(e.span, "ranges outside of a `for` loop"),
            ExprKind::Map(_) => self.unsupported(e.span, "maps"),
            ExprKind::Lambda { .. } => self.unsupported(e.span, "lambdas"),
            ExprKind::Recv(_) | ExprKind::ChanNew { .. } => self.unsupported(e.span, "channels"),
            ExprKind::Float(_) => self.unsupported(e.span, "floats"),
        }
    }

    /// Applies `op` to RAX (left) and RCX (right); the result goes to RAX.
    /// Reference operands are owned and are consumed.
    fn binary_op(&mut self, op: BinOp, operand_ty: &Type) {
        if *operand_ty == Type::Str {
            self.asm.push(RAX);
            self.asm.push(RCX);
            match op {
                BinOp::Add => self.call_runtime("__rt_concat", 2),
                BinOp::Eq => self.call_runtime("__rt_str_eq", 2),
                BinOp::NotEq => {
                    self.call_runtime("__rt_str_eq", 2);
                    self.asm.alu_imm(AluImm::Xor, RAX, 1);
                }
                _ => {
                    // Ordering: compare the result of str_cmp with zero.
                    self.call_runtime("__rt_str_cmp", 2);
                    self.asm.alu_imm(AluImm::Cmp, RAX, 0);
                    self.asm.setcc(cc_of(op));
                }
            }
            return;
        }
        if is_ref(operand_ty) {
            // Lists and structs are compared by content.
            self.asm.push(RAX);
            self.asm.push(RCX);
            let td = self.descriptor(operand_ty);
            self.asm.lea(RAX, td);
            self.asm.push(RAX);
            self.call_runtime("__rt_equals", 3);
            if op == BinOp::NotEq {
                self.asm.alu_imm(AluImm::Xor, RAX, 1);
            }
            return;
        }
        match op {
            BinOp::Add => self.asm.alu(Alu::Add, RAX, RCX),
            BinOp::Sub => self.asm.alu(Alu::Sub, RAX, RCX),
            BinOp::Mul => self.asm.imul(RAX, RCX),
            BinOp::Div | BinOp::Mod => self.divide(op == BinOp::Mod),
            BinOp::And => self.asm.alu(Alu::And, RAX, RCX),
            BinOp::Or => self.asm.alu(Alu::Or, RAX, RCX),
            _ => {
                self.asm.alu(Alu::Cmp, RAX, RCX);
                self.asm.setcc(cc_of(op));
            }
        }
    }

    /// RAX / RCX (or RAX % RCX), with a panic on division by zero.
    fn divide(&mut self, remainder: bool) {
        let (nonzero, plain, done) = (self.asm.new_label(), self.asm.new_label(), self.asm.new_label());
        self.asm.alu(Alu::Test, RCX, RCX);
        self.asm.jcc(Cc::Ne, nonzero);
        let message = self.string("division by zero");
        self.asm.lea(RAX, message);
        self.asm.push(RAX);
        self.call_runtime("__rt_panic", 1);
        self.asm.bind(nonzero);
        // The processor traps on MIN / -1, so dividing by -1 is done by hand.
        self.asm.alu_imm(AluImm::Cmp, RCX, -1);
        self.asm.jcc(Cc::Ne, plain);
        if remainder {
            self.asm.mov_imm(RAX, 0);
        } else {
            self.asm.neg(RAX);
        }
        self.asm.jmp(done);
        self.asm.bind(plain);
        self.asm.cqo();
        self.asm.idiv(RCX);
        if remainder {
            self.asm.mov(RAX, RDX);
        }
        self.asm.bind(done);
    }

    fn push_args(&mut self, args: &[Expr]) {
        for arg in args {
            self.expr(arg);
            self.asm.push(RAX);
        }
    }

    fn call(&mut self, e: &Expr, callee: &Expr, args: &[Expr]) {
        match self.an.calls.get(&e.id).cloned() {
            Some(CallKind::Fn(name)) => {
                self.push_args(args);
                let label = self.fns[&name];
                self.asm.call(label);
                if !args.is_empty() {
                    self.asm.alu_imm(AluImm::Add, RSP, 8 * args.len() as i32);
                }
            }
            Some(CallKind::Method(strukt, name)) => {
                // `self` is the first argument.
                let ExprKind::Field { obj, .. } = &callee.kind else { return };
                self.expr(obj);
                self.asm.push(RAX);
                self.push_args(args);
                let label = self.fns[&method_key(&strukt, &name)];
                self.asm.call(label);
                self.asm.alu_imm(AluImm::Add, RSP, 8 * (args.len() as i32 + 1));
            }
            Some(CallKind::Dynamic) => {
                // A method called through an interface: look it up in the object's type.
                let ExprKind::Field { obj, name, .. } = &callee.kind else {
                    self.unsupported(e.span, "calls through function values");
                    return;
                };
                if !matches!(self.ty(obj), Type::Interface(_)) {
                    self.unsupported(e.span, "calls through function values");
                    return;
                }
                self.expr(obj);
                self.asm.push(RAX);
                self.push_args(args);
                self.asm.load(RAX, RSP, 8 * args.len() as i32);
                self.asm.push(RAX);
                let name_label = self.string(name);
                self.asm.lea(RAX, name_label);
                self.asm.push(RAX);
                self.call_runtime("__rt_find_method", 2);
                self.asm.call_reg(RAX);
                self.asm.alu_imm(AluImm::Add, RSP, 8 * (args.len() as i32 + 1));
            }
            Some(CallKind::Builtin(name)) => self.builtin(&name, e, args),
            Some(CallKind::BuiltinMethod(Recv::Str, name)) if name == "len" => {
                let ExprKind::Field { obj, .. } = &callee.kind else { return };
                self.expr(obj);
                self.asm.push(RAX);
                self.call_runtime("__rt_str_len", 1);
            }
            Some(CallKind::BuiltinMethod(Recv::List, name)) => {
                let ExprKind::Field { obj, .. } = &callee.kind else { return };
                self.list_method(e, obj, &name, args);
            }
            Some(CallKind::BuiltinMethod(_, name)) => {
                self.unsupported(e.span, &format!("calls to the method `{name}`"));
            }
            None => self.unsupported(e.span, "calls through function values"),
        }
    }

    fn list_method(&mut self, e: &Expr, obj: &Expr, name: &str, args: &[Expr]) {
        // (runtime function, arguments whose ownership moves into the list)
        let (function, moved): (&str, &[usize]) = match name {
            "len" => ("__rt_list_len", &[]),
            "push" => ("__rt_list_push", &[0]),
            "insert" => ("__rt_list_insert", &[1]),
            "remove" => ("__rt_list_remove", &[]),
            "clear" => ("__rt_list_clear", &[]),
            "contains" => ("__rt_list_contains", &[]),
            "index_of" => ("__rt_list_index_of", &[]),
            "slice" => ("__rt_list_slice", &[]),
            "reverse" => ("__rt_list_reverse", &[]),
            "join" => ("__rt_list_join", &[]),
            "sort" => ("__rt_list_sort", &[]),
            _ => {
                self.unsupported(e.span, &format!("calls to the list method `{name}`"));
                return;
            }
        };
        self.expr(obj);
        self.asm.push(RAX);
        self.push_args(args);
        self.call_runtime(function, 0);
        // The runtime only borrowed the list and the other arguments: release them.
        self.asm.mov(RDX, RAX);
        for (i, arg) in args.iter().enumerate().rev() {
            self.asm.pop(RAX);
            if is_ref(&self.ty(arg)) && !moved.contains(&i) {
                self.asm.push(RDX);
                self.release_rax();
                self.asm.pop(RDX);
            }
        }
        self.asm.pop(RAX);
        self.asm.push(RDX);
        self.release_rax();
        self.asm.pop(RAX);
    }

    fn builtin(&mut self, name: &str, e: &Expr, args: &[Expr]) {
        match name {
            "print" => {
                // print(a, b) writes "a b\n".
                let pieces = args.len() * 2 - usize::from(!args.is_empty());
                self.concat_all(pieces, |g, i| {
                    if i % 2 == 0 {
                        g.to_str(&args[i / 2]);
                    } else {
                        let space = g.string(" ");
                        g.asm.lea(RAX, space);
                    }
                });
                self.asm.push(RAX);
                self.call_runtime("__rt_print", 1);
            }
            "str" => self.to_str(&args[0]),
            "exit" | "panic" => {
                self.push_args(args);
                self.call_runtime(if name == "exit" { "__rt_exit" } else { "__rt_panic" }, 1);
            }
            "abs" => {
                let done = self.asm.new_label();
                self.expr(&args[0]);
                self.asm.alu_imm(AluImm::Cmp, RAX, 0);
                self.asm.jcc(Cc::Ge, done);
                self.asm.neg(RAX);
                self.asm.bind(done);
            }
            "min" | "max" => {
                let done = self.asm.new_label();
                self.push_args(args);
                self.asm.pop(RCX);
                self.asm.pop(RAX);
                self.asm.alu(Alu::Cmp, RAX, RCX);
                self.asm.jcc(if name == "min" { Cc::Le } else { Cc::Ge }, done);
                self.asm.mov(RAX, RCX);
                self.asm.bind(done);
            }

            // ---- low-level operations reserved to the runtime ----
            "__syscall" => {
                self.push_args(args);
                for reg in [R9, R8, R10, RDX, RSI, RDI, RAX] {
                    self.asm.pop(reg);
                }
                self.asm.syscall();
            }
            "__load8" | "__load64" => {
                self.expr(&args[0]);
                if name == "__load8" {
                    self.asm.load8(RAX, RAX, 0);
                } else {
                    self.asm.load(RAX, RAX, 0);
                }
            }
            "__store8" | "__store64" => {
                self.push_args(args);
                self.asm.pop(RCX);
                self.asm.pop(RAX);
                if name == "__store8" {
                    self.asm.store8(RAX, 0, RCX);
                } else {
                    self.asm.store(RAX, 0, RCX);
                }
            }
            "__state" => self.asm.mov(RAX, R15),
            "__td_string" => {
                let td = self.descriptor(&Type::Str);
                self.asm.lea(RAX, td);
            }
            // The address of a string, without taking a reference.
            "__str_ptr" => {
                if !self.is_local(&args[0]) {
                    self.unsupported(e.span, "`__str_ptr` on anything but a local variable");
                }
                self.operand(&args[0]);
            }
            // An address the runtime owns becomes an owned string.
            "__ptr_str" => self.expr(&args[0]),
            other => self.unsupported(e.span, &format!("calls to `{other}`")),
        }
    }
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
