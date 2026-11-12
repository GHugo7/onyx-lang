//! Native backend: AST + analysis -> x86-64 machine code in a Linux executable.
//!
//! The generated code is a simple stack machine. Every value is 64 bits wide
//! (an integer, a boolean, or the address of a string). An expression leaves
//! its result in RAX; intermediate values are pushed on the stack.
//!
//! Calling convention (private to Onyx): the caller pushes the arguments from
//! first to last, calls, then removes them. The result comes back in RAX.
//! Inside a function, RBP points to the frame: parameters are above it, local
//! variables below. R15 holds the address of the runtime's state page.

mod asm;
mod elf;

use crate::ast::*;
use crate::checker::{Analysis, CallKind, Recv, Type};
use crate::diagnostics::{Diagnostic, Span};
use asm::*;
use std::collections::HashMap;

/// The runtime, written in Onyx and compiled into every native program.
pub const RUNTIME_SOURCE: &str = include_str!("runtime.ox");

pub fn generate(program: &Program, an: &Analysis) -> Result<Vec<u8>, Vec<Diagnostic>> {
    let mut g = Gen {
        an,
        asm: Asm::default(),
        diags: Vec::new(),
        fns: HashMap::new(),
        strings: HashMap::new(),
        scopes: Vec::new(),
        slots: 0,
        params: 0,
        loops: Vec::new(),
        epilogue: None,
    };

    for item in &program.items {
        match item {
            Item::Fn(f) => {
                let label = g.asm.new_label();
                g.fns.insert(f.name.clone(), label);
            }
            Item::Struct(s) => g.unsupported(s.name_span, "structs"),
            Item::Interface(i) => g.unsupported(i.name_span, "interfaces"),
            Item::Global(stmt) => g.unsupported(stmt.span, "top-level variables"),
            Item::Check { .. } | Item::Import { .. } => {}
        }
    }

    // Program entry: set up the runtime's state page, run main, exit(0).
    let entry = g.asm.pos();
    for (reg, value) in [(RAX, 9), (RDI, 0), (RSI, 4096), (RDX, 3), (R10, 0x22), (R8, -1), (R9, 0)] {
        g.asm.mov_imm(reg, value); // mmap(NULL, 4096, READ | WRITE, PRIVATE | ANONYMOUS, -1, 0)
    }
    g.asm.syscall();
    g.asm.mov(R15, RAX);
    if let Some(&main) = g.fns.get("main") {
        g.asm.call(main);
    }
    g.asm.mov_imm(RDI, 0);
    g.asm.mov_imm(RAX, 231); // exit_group
    g.asm.syscall();

    for item in &program.items {
        if let Item::Fn(f) = item {
            g.function(f);
        }
    }

    // Constants live after the code.
    let mut strings: Vec<(Vec<u8>, Label)> = g.strings.iter().map(|(s, l)| (s.clone(), *l)).collect();
    strings.sort_by(|a, b| a.0.cmp(&b.0));
    for (text, label) in strings {
        g.asm.align(8);
        g.asm.bind(label);
        g.asm.bytes(&(text.len() as u64).to_le_bytes());
        g.asm.bytes(&text);
    }

    if !g.diags.is_empty() {
        g.diags.sort_by_key(|d| d.span.start);
        g.diags.dedup_by_key(|d| (d.span.start, d.message.clone()));
        return Err(g.diags);
    }
    Ok(elf::write(&g.asm.finish(), entry))
}

struct Gen<'a> {
    an: &'a Analysis,
    asm: Asm,
    diags: Vec<Diagnostic>,
    fns: HashMap<String, Label>,
    strings: HashMap<Vec<u8>, Label>,
    /// Variable name -> offset from RBP, innermost scope last.
    scopes: Vec<HashMap<String, i32>>,
    /// Local slots used so far by the current function.
    slots: i32,
    params: usize,
    /// (continue target, break target) of the enclosing loops.
    loops: Vec<(Label, Label)>,
    epilogue: Option<Label>,
}

impl<'a> Gen<'a> {
    fn unsupported(&mut self, span: Span, what: &str) {
        self.diags.push(
            Diagnostic::new("E0500", format!("{what} are not supported by the native target yet"), span)
                .help("the native target is new and grows step by step; this program still runs with `onyx run`"),
        );
    }

    fn ty(&self, e: &Expr) -> Type {
        self.an.types.get(&e.id).cloned().unwrap_or(Type::Unknown)
    }

    fn string(&mut self, text: &str) -> Label {
        if let Some(&label) = self.strings.get(text.as_bytes()) {
            return label;
        }
        let label = self.asm.new_label();
        self.strings.insert(text.as_bytes().to_vec(), label);
        label
    }

    fn check_type(&mut self, t: &TypeExpr) {
        match &t.kind {
            TypeKind::Named(n) if matches!(n.as_str(), "int" | "bool" | "string" | "void") => {}
            _ => self.unsupported(t.span, "values of this type"),
        }
    }

    // ---- functions ----

    fn function(&mut self, f: &FnDecl) {
        for p in &f.params {
            self.check_type(&p.ty);
        }
        if let Some(ret) = &f.ret {
            self.check_type(ret);
        }
        if f.fallible {
            self.unsupported(f.name_span, "functions that can fail (`!`)");
        }

        let label = self.fns[&f.name];
        let epilogue = self.asm.new_label();
        self.epilogue = Some(epilogue);
        self.slots = 0;
        self.params = f.params.len();
        self.scopes = vec![HashMap::new()];
        // The first argument was pushed first, so it is the farthest from RBP.
        for (i, p) in f.params.iter().enumerate() {
            let offset = 16 + 8 * (f.params.len() - 1 - i) as i32;
            self.scopes[0].insert(p.name.clone(), offset);
        }

        self.asm.bind(label);
        self.asm.push(RBP);
        self.asm.mov(RBP, RSP);
        self.asm.alu_imm(AluImm::Sub, RSP, 0);
        let frame_size_at = self.asm.pos() - 4;

        for stmt in &f.body.stmts {
            self.stmt(stmt);
        }

        self.asm.mov_imm(RAX, 0);
        self.asm.bind(epilogue);
        self.asm.mov(RSP, RBP);
        self.asm.pop(RBP);
        self.asm.ret();
        self.asm.patch32(frame_size_at, self.slots * 8);
    }

    fn new_slot(&mut self) -> i32 {
        self.slots += 1;
        -8 * self.slots
    }

    fn declare(&mut self, name: &str) -> i32 {
        let offset = self.new_slot();
        self.scopes.last_mut().unwrap().insert(name.to_string(), offset);
        offset
    }

    fn lookup(&self, name: &str) -> Option<i32> {
        self.scopes.iter().rev().find_map(|s| s.get(name)).copied()
    }

    // ---- statements ----

    fn block(&mut self, block: &Block) {
        self.scopes.push(HashMap::new());
        for stmt in &block.stmts {
            self.stmt(stmt);
        }
        self.scopes.pop();
    }

    fn stmt(&mut self, stmt: &Stmt) {
        match &stmt.kind {
            StmtKind::Let { name, init, .. } => {
                self.expr(init);
                let offset = self.declare(name);
                self.asm.store(RBP, offset, RAX);
            }
            StmtKind::Assign { target, op, value } => {
                let ExprKind::Ident(name) = &target.kind else {
                    self.unsupported(target.span, "assignments to fields and elements");
                    return;
                };
                let Some(offset) = self.lookup(name) else {
                    self.unsupported(target.span, "top-level variables");
                    return;
                };
                if *op == AssignOp::Set {
                    self.expr(value);
                } else {
                    let bin = match op {
                        AssignOp::Add => BinOp::Add,
                        AssignOp::Sub => BinOp::Sub,
                        AssignOp::Mul => BinOp::Mul,
                        _ => BinOp::Div,
                    };
                    self.asm.load(RAX, RBP, offset);
                    self.asm.push(RAX);
                    self.expr(value);
                    self.asm.mov(RCX, RAX);
                    self.asm.pop(RAX);
                    let ty = self.ty(target);
                    self.binary_op(bin, &ty);
                }
                self.asm.store(RBP, offset, RAX);
            }
            StmtKind::Expr(e) => self.expr(e),
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
                self.loops.push((top, end));
                self.block(body);
                self.loops.pop();
                self.asm.jmp(top);
                self.asm.bind(end);
            }
            StmtKind::For { var, iter, body, .. } => {
                let ExprKind::Range { lo, hi } = &iter.kind else {
                    self.unsupported(iter.span, "loops over anything but a range (`a..b`)");
                    return;
                };
                let (top, next, end) = (self.asm.new_label(), self.asm.new_label(), self.asm.new_label());
                self.scopes.push(HashMap::new());
                self.expr(lo);
                let counter = self.declare(var);
                self.asm.store(RBP, counter, RAX);
                self.expr(hi);
                let limit = self.new_slot();
                self.asm.store(RBP, limit, RAX);

                self.asm.bind(top);
                self.asm.load(RAX, RBP, counter);
                self.asm.load(RCX, RBP, limit);
                self.asm.alu(Alu::Cmp, RAX, RCX);
                self.asm.jcc(Cc::Ge, end);
                self.loops.push((next, end));
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
            StmtKind::Return(value) => {
                match value {
                    Some(v) => self.expr(v),
                    None => self.asm.mov_imm(RAX, 0),
                }
                let epilogue = self.epilogue.unwrap();
                self.asm.jmp(epilogue);
            }
            StmtKind::Break => {
                let (_, end) = *self.loops.last().unwrap();
                self.asm.jmp(end);
            }
            StmtKind::Continue => {
                let (next, _) = *self.loops.last().unwrap();
                self.asm.jmp(next);
            }
            StmtKind::Block(body) => self.block(body),
            StmtKind::Fail(_) => self.unsupported(stmt.span, "`fail` statements"),
            StmtKind::Fork(_) => self.unsupported(stmt.span, "`fork` blocks"),
            StmtKind::Send { .. } => self.unsupported(stmt.span, "channels"),
        }
    }

    // ---- expressions ----

    /// Calls a runtime function whose arguments are already on the stack.
    fn call_runtime(&mut self, name: &str, args: usize) {
        let label = *self.fns.get(name).unwrap_or_else(|| panic!("missing runtime function {name}"));
        self.asm.call(label);
        if args > 0 {
            self.asm.alu_imm(AluImm::Add, RSP, 8 * args as i32);
        }
    }

    /// Evaluates `e` and converts the result to a string (in RAX).
    fn to_str(&mut self, e: &Expr) {
        self.expr(e);
        let convert = match self.ty(e) {
            Type::Int => "__rt_int_str",
            Type::Bool => "__rt_bool_str",
            _ => return,
        };
        self.asm.push(RAX);
        self.call_runtime(convert, 1);
    }

    /// Joins strings: each closure leaves one string in RAX.
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

    fn expr(&mut self, e: &Expr) {
        let ty = self.ty(e);
        if !matches!(ty, Type::Int | Type::Bool | Type::Str | Type::Void | Type::Range | Type::Unknown) {
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
                Some(offset) => self.asm.load(RAX, RBP, offset),
                None => self.unsupported(e.span, "functions used as values and top-level variables"),
            },
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
                let operand_ty = self.ty(lhs);
                self.binary_op(*op, &operand_ty);
            }
            ExprKind::Call { callee, args } => self.call(e, callee, args),
            ExprKind::Try(inner) => self.expr(inner),
            ExprKind::Range { .. } => self.unsupported(e.span, "ranges outside of a `for` loop"),
            ExprKind::List(_) => self.unsupported(e.span, "lists"),
            ExprKind::Map(_) => self.unsupported(e.span, "maps"),
            ExprKind::StructLit { .. } => self.unsupported(e.span, "structs"),
            ExprKind::Field { .. } => self.unsupported(e.span, "fields"),
            ExprKind::Index { .. } => self.unsupported(e.span, "indexing"),
            ExprKind::Lambda { .. } => self.unsupported(e.span, "lambdas"),
            ExprKind::Or { .. } | ExprKind::Catch { .. } => self.unsupported(e.span, "`or` and `catch`"),
            ExprKind::Recv(_) | ExprKind::ChanNew { .. } => self.unsupported(e.span, "channels"),
            ExprKind::Float(_) => self.unsupported(e.span, "floats"),
        }
    }

    /// Applies `op` to RAX (left) and RCX (right); the result goes to RAX.
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
            Some(CallKind::Builtin(name)) => self.builtin(&name, e, args),
            Some(CallKind::BuiltinMethod(Recv::Str, name)) if name == "len" => {
                let ExprKind::Field { obj, .. } = &callee.kind else { return };
                self.expr(obj);
                self.asm.push(RAX);
                self.call_runtime("__rt_str_len", 1);
            }
            Some(CallKind::BuiltinMethod(_, name)) => {
                self.unsupported(e.span, &format!("calls to the method `{name}`"));
            }
            Some(CallKind::Method(..)) => self.unsupported(e.span, "methods"),
            Some(CallKind::Dynamic) | None => self.unsupported(e.span, "calls through function values"),
        }
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
            "__str_ptr" | "__ptr_str" => self.expr(&args[0]),
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
