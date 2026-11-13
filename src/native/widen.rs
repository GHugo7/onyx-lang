//! Makes the conversions from `int` to `float` explicit.
//!
//! Onyx accepts an int wherever a float is expected: `var x: float = 3`,
//! `sqrt(2)`, `2 * 1.5`. In JavaScript the two are the same kind of number
//! and nothing has to happen. Natively an int and a float with the same value
//! are different bits, so the int must be converted where it is used as a
//! float. The checker noted every such expression (`Analysis::widened`); this
//! pass rewrites each one:
//!
//!     var x: float = 3            var x: float = 3.0
//!     sqrt(n)               =>    sqrt(float(n))
//!     total += count              total += float(count)
//!
//! Afterwards every expression really has the type the checker gave it, and
//! the code generator never has to guess.

use crate::ast::*;
use crate::checker::{Analysis, CallKind, Type};

pub fn widen(program: &mut Program, an: &mut Analysis) {
    if an.widened.is_empty() {
        return;
    }
    let next_id = an.types.keys().max().map_or(0, |id| id + 1);
    let mut w = Widen { an, next_id };
    for item in &mut program.items {
        match item {
            Item::Fn(f) => w.block(&mut f.body),
            Item::Struct(s) => {
                for m in &mut s.methods {
                    w.block(&mut m.body);
                }
            }
            Item::Global(stmt) => w.stmt(stmt),
            Item::Check { body, .. } => w.block(body),
            Item::Interface(_) | Item::Import { .. } => {}
        }
    }
}

struct Widen<'a> {
    an: &'a mut Analysis,
    next_id: usize,
}

impl<'a> Widen<'a> {
    fn fresh(&mut self, ty: Type) -> usize {
        let id = self.next_id;
        self.next_id += 1;
        self.an.types.insert(id, ty);
        id
    }

    fn block(&mut self, block: &mut Block) {
        for stmt in &mut block.stmts {
            self.stmt(stmt);
        }
    }

    fn stmt(&mut self, stmt: &mut Stmt) {
        match &mut stmt.kind {
            StmtKind::Let { init: e, .. } | StmtKind::Expr(e) | StmtKind::Fail(e) | StmtKind::Return(Some(e)) => self.expr(e),
            StmtKind::Return(None) | StmtKind::Break | StmtKind::Continue => {}
            StmtKind::Assign { target, value, .. } => {
                self.expr(target);
                self.expr(value);
            }
            StmtKind::If { cond, then, els } => {
                self.expr(cond);
                self.block(then);
                if let Some(other) = els {
                    self.stmt(other);
                }
            }
            StmtKind::While { cond, body } => {
                self.expr(cond);
                self.block(body);
            }
            StmtKind::For { iter, body, .. } => {
                self.expr(iter);
                self.block(body);
            }
            StmtKind::Fork(body) | StmtKind::Block(body) => self.block(body),
            StmtKind::Send { chan, value } => {
                self.expr(chan);
                self.expr(value);
            }
        }
    }

    fn expr(&mut self, e: &mut Expr) {
        match &mut e.kind {
            ExprKind::Int(_) | ExprKind::Float(_) | ExprKind::Bool(_) | ExprKind::Ident(_) => {}
            ExprKind::Str(parts) => {
                for part in parts {
                    if let StrPart::Expr(inner) = part {
                        self.expr(inner);
                    }
                }
            }
            ExprKind::List(items) => items.iter_mut().for_each(|item| self.expr(item)),
            ExprKind::Map(entries) => {
                for (key, value) in entries {
                    self.expr(key);
                    self.expr(value);
                }
            }
            ExprKind::StructLit { fields, .. } => fields.iter_mut().for_each(|f| self.expr(&mut f.value)),
            ExprKind::Unary { expr, .. } | ExprKind::Try(expr) | ExprKind::Recv(expr) => self.expr(expr),
            ExprKind::Field { obj, .. } => self.expr(obj),
            ExprKind::Binary { lhs, rhs, .. } => {
                self.expr(lhs);
                self.expr(rhs);
            }
            ExprKind::Index { obj, index } => {
                self.expr(obj);
                self.expr(index);
            }
            ExprKind::Range { lo, hi } => {
                self.expr(lo);
                self.expr(hi);
            }
            ExprKind::Call { callee, args } => {
                self.expr(callee);
                args.iter_mut().for_each(|arg| self.expr(arg));
            }
            ExprKind::Lambda { body, .. } => self.block(body),
            ExprKind::Or { expr, default } => {
                self.expr(expr);
                self.expr(default);
            }
            ExprKind::Catch { expr, body, .. } => {
                self.expr(expr);
                self.block(body);
            }
            ExprKind::ChanNew { cap, .. } => {
                if let Some(cap) = cap {
                    self.expr(cap);
                }
            }
        }
        if !self.an.widened.contains(&e.id) {
            return;
        }
        if let ExprKind::Int(n) = e.kind {
            // A literal changes on the spot.
            e.kind = ExprKind::Float(n as f64);
            self.an.types.insert(e.id, Type::Float);
            return;
        }
        // Anything else is converted when the program runs: `float(e)`.
        let span = e.span;
        let callee = Expr { id: self.fresh(Type::Unknown), span, kind: ExprKind::Ident("float".to_string()) };
        let id = self.fresh(Type::Float);
        self.an.calls.insert(id, CallKind::Builtin("float".to_string()));
        let inner = std::mem::replace(e, Expr { id, span, kind: ExprKind::Bool(false) });
        e.kind = ExprKind::Call { callee: Box::new(callee), args: vec![inner] };
    }
}
