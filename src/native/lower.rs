//! Prepares error handling for the native code generator.
//!
//! When a call followed by `?` fails, the function returns on the spot. If
//! that happens in the middle of a larger expression, the values already
//! computed for it (the other arguments of a call, the left side of a `+`...)
//! would be left behind, never released. This pass rewrites such statements
//! so that every `?` sits at the root of a statement, where nothing is
//! pending: whatever is computed before it goes into temporary variables,
//! in the original order.
//!
//!     var x = f(a(), b()?)        var $t1 = a()
//!                           =>    var $t2 = b()?
//!                                 var x = f($t1, $t2)
//!
//! `catch` blocks, which may also leave the function, get the same treatment
//! when they are used in an assignment to a field or an element.
//!
//! The JavaScript target does not need any of this: exceptions unwind for it.

use crate::ast::*;
use crate::checker::{Analysis, CallKind, Type};
use crate::diagnostics::Span;
use std::collections::HashSet;

/// Temporary variables get positions past any real source, so that they
/// never share a key with a variable of the program (see `plan.rs`).
const TEMP_POSITIONS: usize = usize::MAX / 2;

pub fn lower(program: &mut Program, an: &mut Analysis) {
    let globals: HashSet<String> = program
        .items
        .iter()
        .filter_map(|item| match item {
            Item::Global(Stmt { kind: StmtKind::Let { name, .. }, .. }) => Some(name.clone()),
            _ => None,
        })
        .collect();
    let next_id = an.types.keys().max().map_or(0, |id| id + 1);
    let mut l = Lower { an, globals, next_id, temps: 0 };
    for item in &mut program.items {
        match item {
            Item::Fn(f) => l.block(&mut f.body),
            Item::Struct(s) => {
                for m in &mut s.methods {
                    l.block(&mut m.body);
                }
            }
            // A top-level variable may hold a lambda.
            Item::Global(Stmt { kind: StmtKind::Let { init, .. }, .. }) => l.lambdas(init),
            _ => {}
        }
    }
}

/// Does evaluating `e` reach a `?` (lambda bodies are separate functions)?
fn contains_try(e: &Expr) -> bool {
    match &e.kind {
        ExprKind::Try(_) => true,
        ExprKind::Int(_) | ExprKind::Float(_) | ExprKind::Bool(_) | ExprKind::Ident(_) | ExprKind::Lambda { .. } => false,
        ExprKind::Str(parts) => parts.iter().any(|p| matches!(p, StrPart::Expr(inner) if contains_try(inner))),
        ExprKind::List(items) => items.iter().any(contains_try),
        ExprKind::Map(entries) => entries.iter().any(|(k, v)| contains_try(k) || contains_try(v)),
        ExprKind::StructLit { fields, .. } => fields.iter().any(|f| contains_try(&f.value)),
        ExprKind::Unary { expr, .. } | ExprKind::Recv(expr) => contains_try(expr),
        ExprKind::Field { obj, .. } => contains_try(obj),
        ExprKind::Binary { lhs, rhs, .. } => contains_try(lhs) || contains_try(rhs),
        ExprKind::Index { obj, index } => contains_try(obj) || contains_try(index),
        ExprKind::Range { lo, hi } => contains_try(lo) || contains_try(hi),
        ExprKind::Call { callee, args } => contains_try(callee) || args.iter().any(contains_try),
        ExprKind::Or { expr, default } => contains_try(expr) || contains_try(default),
        // The block of a `catch` is made of statements, lowered on their own.
        ExprKind::Catch { expr, .. } => contains_try(expr),
        ExprKind::ChanNew { cap, .. } => cap.as_ref().is_some_and(|c| contains_try(c)),
    }
}

struct Lower<'a> {
    an: &'a mut Analysis,
    globals: HashSet<String>,
    next_id: usize,
    temps: usize,
}

impl<'a> Lower<'a> {
    fn ty(&self, e: &Expr) -> Type {
        self.an.types.get(&e.id).cloned().unwrap_or(Type::Unknown)
    }

    /// A new expression node of a known type.
    fn node(&mut self, kind: ExprKind, ty: Type, span: Span) -> Expr {
        let id = self.next_id;
        self.next_id += 1;
        self.an.types.insert(id, ty);
        Expr { id, span, kind }
    }

    /// A literal or a local variable can be read later without any difference.
    fn is_stable(&self, e: &Expr) -> bool {
        match &e.kind {
            ExprKind::Int(_) | ExprKind::Float(_) | ExprKind::Bool(_) => true,
            ExprKind::Str(parts) => parts.iter().all(|p| matches!(p, StrPart::Lit(_))),
            // A name that no top-level variable has can only be a local one.
            ExprKind::Ident(name) => !self.globals.contains(name),
            _ => false,
        }
    }

    /// Emits `var $tN = value` and returns a reference to that variable.
    fn temp(&mut self, value: Expr, out: &mut Vec<Stmt>) -> Expr {
        let (ty, span) = (self.ty(&value), value.span);
        self.temps += 1;
        let name = format!("$t{}", self.temps);
        let position = TEMP_POSITIONS + self.temps;
        out.push(Stmt {
            span,
            kind: StmtKind::Let {
                name: name.clone(),
                name_span: Span::new(position, position),
                mutable: true,
                ty: None,
                init: value,
            },
        });
        self.node(ExprKind::Ident(name), ty, span)
    }

    /// Another reference to the variable that `e` names.
    fn again(&mut self, e: &Expr) -> Expr {
        let ty = self.ty(e);
        self.node(e.kind.clone(), ty, e.span)
    }

    /// Moves `e` into a temporary variable unless reading it later is the same.
    fn settle(&mut self, e: &mut Expr, out: &mut Vec<Stmt>) {
        if !self.is_stable(e) {
            let value = std::mem::replace(e, Expr { id: 0, span: e.span, kind: ExprKind::Bool(false) });
            *e = self.temp(value, out);
        }
    }

    /// The operands of an expression are evaluated one after the other. Those
    /// up to the last one that contains a `?` are computed beforehand, in
    /// order, so that nothing is pending when the `?` is reached.
    fn operands(&mut self, mut children: Vec<&mut Expr>, out: &mut Vec<Stmt>) {
        let Some(last) = children.iter().rposition(|c| contains_try(c)) else { return };
        for child in children.iter_mut().take(last + 1) {
            self.expr(child, out);
            self.settle(child, out);
        }
    }

    /// Like `operands`, for values that are turned into text (the arguments
    /// of `print`, the parts of an interpolated string). A list or a struct
    /// is shown as it is at that moment: what is kept for later is its text,
    /// not the object, which a later operand could still change.
    fn shown(&mut self, mut children: Vec<&mut Expr>, out: &mut Vec<Stmt>) {
        let Some(last) = children.iter().rposition(|c| contains_try(c)) else { return };
        for child in children.iter_mut().take(last + 1) {
            self.expr(child, out);
            self.settle(child, out);
            if matches!(self.ty(child), Type::List(_) | Type::Map(..) | Type::Struct(_) | Type::Interface(_)) {
                let span = child.span;
                let value = std::mem::replace(&mut **child, Expr { id: 0, span, kind: ExprKind::Bool(false) });
                let callee = self.node(ExprKind::Ident("str".to_string()), Type::Unknown, span);
                let text = self.node(ExprKind::Call { callee: Box::new(callee), args: vec![value] }, Type::Str, span);
                self.an.calls.insert(text.id, CallKind::Builtin("str".to_string()));
                **child = self.temp(text, out);
            }
        }
    }

    /// The receiver and the arguments of a call.
    fn call_operands(&mut self, call: &mut Expr, out: &mut Vec<Stmt>) {
        if matches!(self.an.calls.get(&call.id), Some(CallKind::Builtin(name)) if name == "print" || name == "str") {
            if let ExprKind::Call { args, .. } = &mut call.kind {
                self.shown(args.iter_mut().collect(), out);
            }
            return;
        }
        if let ExprKind::Call { callee, args } = &mut call.kind {
            let mut children: Vec<&mut Expr> = Vec::new();
            if matches!(callee.kind, ExprKind::Field { .. }) {
                if let ExprKind::Field { obj, .. } = &mut callee.kind {
                    children.push(obj);
                }
            } else if !matches!(callee.kind, ExprKind::Ident(_)) {
                children.push(callee);
            }
            children.extend(args.iter_mut());
            self.operands(children, out);
        }
    }

    /// Rewrites `e` so that it contains no `?`, except possibly at its very
    /// root (a call followed by `?` whose operands have none).
    fn expr(&mut self, e: &mut Expr, out: &mut Vec<Stmt>) {
        if let ExprKind::Catch { expr, body, .. } = &mut e.kind {
            self.call_operands(expr, out);
            self.block(body);
            return;
        }
        if !contains_try(e) {
            return;
        }
        let (span, ty) = (e.span, self.ty(e));
        match &mut e.kind {
            ExprKind::Try(call) => self.call_operands(call, out),
            ExprKind::Binary { op: op @ (BinOp::And | BinOp::Or), lhs, rhs } if contains_try(rhs) => {
                // The right side only runs for some values of the left side:
                //     var $t = lhs
                //     if $t { $t = rhs }          (`if !$t` for `||`)
                let is_and = *op == BinOp::And;
                self.expr(lhs, out);
                let left = std::mem::replace(&mut **lhs, Expr { id: 0, span, kind: ExprKind::Bool(false) });
                let result = self.temp(left, out);
                let mut then = Vec::new();
                self.expr(rhs, &mut then);
                let right = std::mem::replace(&mut **rhs, Expr { id: 0, span, kind: ExprKind::Bool(false) });
                then.push(Stmt {
                    span,
                    kind: StmtKind::Assign { target: self.again(&result), op: AssignOp::Set, value: right },
                });
                let mut cond = self.again(&result);
                if !is_and {
                    cond = self.node(ExprKind::Unary { op: UnOp::Not, expr: Box::new(cond) }, Type::Bool, span);
                }
                out.push(Stmt { span, kind: StmtKind::If { cond, then: Block { stmts: then, span }, els: None } });
                *e = result;
            }
            ExprKind::Or { expr, default } if contains_try(default) => {
                // The default only runs when the call fails:
                //     var $t = call catch $e { ...; default }
                self.call_operands(expr, out);
                let mut body = Vec::new();
                self.expr(default, &mut body);
                let fallback = std::mem::replace(&mut **default, Expr { id: 0, span, kind: ExprKind::Bool(false) });
                body.push(Stmt { span, kind: StmtKind::Expr(fallback) });
                let call = std::mem::replace(&mut **expr, Expr { id: 0, span, kind: ExprKind::Bool(false) });
                self.temps += 1;
                let position = TEMP_POSITIONS + self.temps;
                let caught = self.node(
                    ExprKind::Catch {
                        expr: Box::new(call),
                        name: format!("$e{}", self.temps),
                        name_span: Span::new(position, position),
                        body: Block { stmts: body, span },
                    },
                    ty,
                    span,
                );
                self.an.catch_values.insert(caught.id);
                *e = self.temp(caught, out);
            }
            ExprKind::Or { expr, .. } => self.call_operands(expr, out),
            ExprKind::Str(parts) => {
                let children = parts
                    .iter_mut()
                    .filter_map(|p| match p {
                        StrPart::Expr(inner) => Some(inner),
                        StrPart::Lit(_) => None,
                    })
                    .collect();
                self.shown(children, out);
            }
            ExprKind::List(items) => self.operands(items.iter_mut().collect(), out),
            ExprKind::Map(entries) => {
                let children = entries.iter_mut().flat_map(|(k, v)| [k, v]).collect();
                self.operands(children, out);
            }
            ExprKind::StructLit { name, fields, .. } => {
                // Fields are evaluated in the order of the struct's declaration.
                let order: Vec<String> =
                    self.an.structs.get(name.as_str()).map(|s| s.fields.iter().map(|(n, _)| n.clone()).collect()).unwrap_or_default();
                let mut children: Vec<&mut FieldInit> = fields.iter_mut().collect();
                children.sort_by_key(|f| order.iter().position(|n| n == &f.name));
                self.operands(children.into_iter().map(|f| &mut f.value).collect(), out);
            }
            ExprKind::Unary { expr, .. } | ExprKind::Recv(expr) => self.operands(vec![expr], out),
            ExprKind::Field { obj, .. } => self.operands(vec![obj], out),
            ExprKind::Binary { lhs, rhs, .. } => self.operands(vec![lhs, rhs], out),
            ExprKind::Index { obj, index } => self.operands(vec![obj, index], out),
            ExprKind::Range { lo, hi } => self.operands(vec![lo, hi], out),
            ExprKind::Call { .. } => self.call_operands(e, out),
            ExprKind::ChanNew { cap, .. } => {
                if let Some(cap) = cap {
                    self.operands(vec![cap], out);
                }
            }
            ExprKind::Int(_) | ExprKind::Float(_) | ExprKind::Bool(_) | ExprKind::Ident(_) | ExprKind::Lambda { .. } | ExprKind::Catch { .. } => {}
        }
    }

    fn block(&mut self, block: &mut Block) {
        let mut out = Vec::with_capacity(block.stmts.len());
        for stmt in block.stmts.drain(..) {
            self.stmt(stmt, &mut out);
        }
        block.stmts = out;
    }

    /// Lambdas are functions of their own: their bodies are lowered as such.
    fn lambdas(&mut self, e: &mut Expr) {
        match &mut e.kind {
            ExprKind::Int(_) | ExprKind::Float(_) | ExprKind::Bool(_) | ExprKind::Ident(_) => {}
            ExprKind::Lambda { body, .. } => self.block(body),
            ExprKind::Str(parts) => {
                for part in parts {
                    if let StrPart::Expr(inner) = part {
                        self.lambdas(inner);
                    }
                }
            }
            ExprKind::List(items) => items.iter_mut().for_each(|item| self.lambdas(item)),
            ExprKind::Map(entries) => {
                for (key, value) in entries {
                    self.lambdas(key);
                    self.lambdas(value);
                }
            }
            ExprKind::StructLit { fields, .. } => fields.iter_mut().for_each(|f| self.lambdas(&mut f.value)),
            ExprKind::Unary { expr, .. } | ExprKind::Try(expr) | ExprKind::Recv(expr) => self.lambdas(expr),
            ExprKind::Field { obj, .. } => self.lambdas(obj),
            ExprKind::Binary { lhs, rhs, .. } => {
                self.lambdas(lhs);
                self.lambdas(rhs);
            }
            ExprKind::Index { obj, index } => {
                self.lambdas(obj);
                self.lambdas(index);
            }
            ExprKind::Range { lo, hi } => {
                self.lambdas(lo);
                self.lambdas(hi);
            }
            ExprKind::Call { callee, args } => {
                self.lambdas(callee);
                args.iter_mut().for_each(|arg| self.lambdas(arg));
            }
            ExprKind::Or { expr, default } => {
                self.lambdas(expr);
                self.lambdas(default);
            }
            // The block of a `catch` is lowered with the statement it belongs to.
            ExprKind::Catch { expr, .. } => self.lambdas(expr),
            ExprKind::ChanNew { cap, .. } => {
                if let Some(cap) = cap {
                    self.lambdas(cap);
                }
            }
        }
    }

    /// Lowers one statement into `out` (what it needs first, then itself).
    fn stmt(&mut self, mut stmt: Stmt, out: &mut Vec<Stmt>) {
        let span = stmt.span;
        match &mut stmt.kind {
            StmtKind::Let { init: e, .. } | StmtKind::Expr(e) | StmtKind::Fail(e) | StmtKind::Return(Some(e)) => self.lambdas(e),
            StmtKind::Assign { target, value, .. } => {
                self.lambdas(target);
                self.lambdas(value);
            }
            StmtKind::If { cond: e, .. } | StmtKind::While { cond: e, .. } | StmtKind::For { iter: e, .. } => self.lambdas(e),
            StmtKind::Send { chan, value } => {
                self.lambdas(chan);
                self.lambdas(value);
            }
            _ => {}
        }
        match &mut stmt.kind {
            StmtKind::Let { init: e, .. } | StmtKind::Expr(e) | StmtKind::Fail(e) | StmtKind::Return(Some(e)) => {
                self.expr(e, out);
            }
            StmtKind::Return(None) | StmtKind::Break | StmtKind::Continue => {}
            StmtKind::Assign { target, op, value } => {
                let leaves = contains_try(target) || contains_try(value) || matches!(value.kind, ExprKind::Catch { .. });
                let direct = matches!(target.kind, ExprKind::Ident(_)) && *op == AssignOp::Set;
                if !leaves && *op != AssignOp::Set && self.ty(target) == Type::Float {
                    // The code generator updates integers in place; a float
                    // is computed and then stored: `x += v` becomes `x = x + v`.
                    match &mut target.kind {
                        ExprKind::Field { obj, .. } => self.settle(obj, out),
                        ExprKind::Index { obj, index } => {
                            self.settle(obj, out);
                            self.settle(index, out);
                        }
                        _ => {}
                    }
                    let bin = match *op {
                        AssignOp::Add => BinOp::Add,
                        AssignOp::Sub => BinOp::Sub,
                        AssignOp::Mul => BinOp::Mul,
                        _ => BinOp::Div,
                    };
                    let current = self.reader(target);
                    let amount = std::mem::replace(value, Expr { id: 0, span, kind: ExprKind::Bool(false) });
                    *value = self.node(ExprKind::Binary { op: bin, lhs: Box::new(current), rhs: Box::new(amount) }, Type::Float, span);
                    *op = AssignOp::Set;
                } else if !leaves || direct {
                    self.expr(value, out);
                } else {
                    // The object and the position are computed first, then
                    // the value, and only then is anything stored.
                    match &mut target.kind {
                        ExprKind::Field { obj, .. } => {
                            self.expr(obj, out);
                            self.settle(obj, out);
                        }
                        ExprKind::Index { obj, index } => {
                            self.expr(obj, out);
                            self.settle(obj, out);
                            self.expr(index, out);
                            self.settle(index, out);
                        }
                        _ => {}
                    }
                    let bin = match *op {
                        AssignOp::Set => None,
                        AssignOp::Add => Some(BinOp::Add),
                        AssignOp::Sub => Some(BinOp::Sub),
                        AssignOp::Mul => Some(BinOp::Mul),
                        AssignOp::Div => Some(BinOp::Div),
                    };
                    // `target op= value` reads the target before computing the value.
                    let current = bin.map(|_| {
                        let read = self.reader(target);
                        self.temp(read, out)
                    });
                    self.expr(value, out);
                    let computed = std::mem::replace(value, Expr { id: 0, span, kind: ExprKind::Bool(false) });
                    let mut result = self.temp(computed, out);
                    if let (Some(bin), Some(current)) = (bin, current) {
                        let ty = self.ty(target);
                        result = self.node(ExprKind::Binary { op: bin, lhs: Box::new(current), rhs: Box::new(result) }, ty, span);
                    }
                    *value = result;
                    *op = AssignOp::Set;
                }
            }
            StmtKind::If { cond, then, els } => {
                self.expr(cond, out);
                self.block(then);
                if let Some(other) = els.take() {
                    // What an `else if` needs first must only run when it is reached.
                    let mut inner = Vec::new();
                    self.stmt(*other, &mut inner);
                    let lowered = if inner.len() == 1 {
                        inner.pop().unwrap()
                    } else {
                        Stmt { span, kind: StmtKind::Block(Block { stmts: inner, span }) }
                    };
                    *els = Some(Box::new(lowered));
                }
            }
            StmtKind::While { cond, body } => {
                self.block(body);
                let mut before = Vec::new();
                self.expr(cond, &mut before);
                if !before.is_empty() {
                    // The condition needs statements on every turn:
                    //     while true { ...; var $c = cond; if !$c { break }; body }
                    let test = std::mem::replace(cond, self.node(ExprKind::Bool(true), Type::Bool, span));
                    let passed = self.temp(test, &mut before);
                    let stop = self.node(ExprKind::Unary { op: UnOp::Not, expr: Box::new(passed) }, Type::Bool, span);
                    let leave = Stmt { span, kind: StmtKind::Break };
                    before.push(Stmt {
                        span,
                        kind: StmtKind::If { cond: stop, then: Block { stmts: vec![leave], span }, els: None },
                    });
                    before.append(&mut body.stmts);
                    body.stmts = before;
                }
            }
            StmtKind::For { iter, body, .. } => {
                self.expr(iter, out);
                self.block(body);
            }
            StmtKind::Fork(body) | StmtKind::Block(body) => self.block(body),
            StmtKind::Send { chan, value } => {
                self.expr(chan, out);
                self.expr(value, out);
            }
        }
        out.push(stmt);
    }

    /// An expression that reads what the assignment target `target` holds.
    fn reader(&mut self, target: &Expr) -> Expr {
        let ty = self.ty(target);
        let kind = match &target.kind {
            ExprKind::Field { obj, name, name_span } => {
                ExprKind::Field { obj: Box::new(self.again(obj)), name: name.clone(), name_span: *name_span }
            }
            ExprKind::Index { obj, index } => {
                ExprKind::Index { obj: Box::new(self.again(obj)), index: Box::new(self.again(index)) }
            }
            other => other.clone(),
        };
        self.node(kind, ty, target.span)
    }
}
