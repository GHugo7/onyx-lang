//! Compile-time simplification, shared by every backend.
//!
//! Runs after type checking, on a program known to be correct, and never
//! changes what the program does:
//!   - constant expressions are computed (`2 * 60` becomes `120`);
//!   - `const` values that are plain literals are copied into their uses;
//!   - literal pieces of string interpolations are merged;
//!   - branches that can never run, and statements after a `return`,
//!     `break`, `continue` or `fail`, are removed.
//!
//! Nodes keep their ids, so the checker's side tables stay valid. A node is
//! only ever replaced by a literal or by one of its own children.

use crate::ast::*;
use std::collections::HashMap;

/// 2^53 - 1. Beyond it the JavaScript target is not exact, so integers out of
/// that range are left for the program to compute on its target.
const MAX_SAFE: u64 = 9_007_199_254_740_991;

/// String constants up to this size are copied into their uses.
const MAX_INLINE_STR: usize = 64;

#[derive(Clone)]
enum Lit {
    Int(i64),
    Float(f64),
    Bool(bool),
    Str(String),
}

impl Lit {
    fn into_kind(self) -> ExprKind {
        match self {
            Lit::Int(n) => ExprKind::Int(n),
            Lit::Float(x) => ExprKind::Float(x),
            Lit::Bool(b) => ExprKind::Bool(b),
            Lit::Str(s) => ExprKind::Str(vec![StrPart::Lit(s)]),
        }
    }
}

/// The text of a string literal without interpolation.
fn plain_str(e: &Expr) -> Option<&str> {
    match &e.kind {
        ExprKind::Str(parts) => match parts.as_slice() {
            [] => Some(""),
            [StrPart::Lit(s)] => Some(s),
            _ => None,
        },
        _ => None,
    }
}

/// The value a constant declared as `const name: ty = init` stands for.
fn constant(init: &Expr, ty: &Option<TypeExpr>) -> Option<Lit> {
    let is_float = matches!(ty, Some(TypeExpr { kind: TypeKind::Named(n), .. }) if n == "float");
    match &init.kind {
        // `const HALF: float = 1` is the float 1.0 wherever it is used.
        ExprKind::Int(n) if is_float => Some(Lit::Float(*n as f64)),
        ExprKind::Int(n) => Some(Lit::Int(*n)),
        ExprKind::Float(x) => Some(Lit::Float(*x)),
        ExprKind::Bool(b) => Some(Lit::Bool(*b)),
        _ => plain_str(init).filter(|s| s.len() <= MAX_INLINE_STR).map(|s| Lit::Str(s.to_string())),
    }
}

fn is_propagated_const(stmt: &Stmt) -> bool {
    matches!(&stmt.kind, StmtKind::Let { mutable: false, init, ty, .. } if constant(init, ty).is_some())
}

pub fn optimize(program: &mut Program) {
    let mut f = Folder { scopes: vec![HashMap::new()] };

    // Top-level variables first: they are visible in every function.
    for item in &mut program.items {
        if let Item::Global(Stmt { kind: StmtKind::Let { name, mutable, init, ty, .. }, .. }) = item {
            f.expr(init);
            let value = if *mutable { None } else { constant(init, ty) };
            f.scopes[0].insert(name.clone(), value);
        }
    }
    for item in &mut program.items {
        match item {
            Item::Fn(function) => f.function(function),
            Item::Struct(s) => {
                for method in &mut s.methods {
                    f.function(method);
                }
            }
            Item::Check { body, .. } => f.block(body),
            _ => {}
        }
    }
    // Constants that were copied into all their uses are not needed any more.
    program.items.retain(|item| !matches!(item, Item::Global(stmt) if is_propagated_const(stmt)));
}

/// What a node should become.
enum Simplified {
    Kind(ExprKind),
    Lhs,
    Rhs,
}

struct Folder {
    /// Names in scope. `Some` for a constant with a known value, `None` for
    /// anything else (which hides an outer constant of the same name).
    scopes: Vec<HashMap<String, Option<Lit>>>,
}

impl Folder {
    fn lookup(&self, name: &str) -> Option<Lit> {
        self.scopes.iter().rev().find_map(|scope| scope.get(name)).cloned().flatten()
    }

    fn declare(&mut self, name: &str, value: Option<Lit>) {
        self.scopes.last_mut().unwrap().insert(name.to_string(), value);
    }

    fn function(&mut self, f: &mut FnDecl) {
        self.scopes.push(HashMap::new());
        if f.has_self {
            self.declare("self", None);
        }
        for p in &f.params {
            self.declare(&p.name, None);
        }
        self.stmts(&mut f.body.stmts);
        self.scopes.pop();
    }

    fn block(&mut self, block: &mut Block) {
        self.scopes.push(HashMap::new());
        self.stmts(&mut block.stmts);
        self.scopes.pop();
    }

    fn stmts(&mut self, stmts: &mut Vec<Stmt>) {
        let mut kept = Vec::with_capacity(stmts.len());
        for mut stmt in stmts.drain(..) {
            if !self.stmt(&mut stmt) {
                continue;
            }
            let leaves = matches!(
                stmt.kind,
                StmtKind::Return(_) | StmtKind::Break | StmtKind::Continue | StmtKind::Fail(_)
            );
            kept.push(stmt);
            if leaves {
                break; // nothing after this can run
            }
        }
        *stmts = kept;
    }

    /// Simplifies a statement. Returns false when it has no effect left and
    /// should be dropped.
    fn stmt(&mut self, stmt: &mut Stmt) -> bool {
        let mut replacement: Option<StmtKind> = None;
        match &mut stmt.kind {
            StmtKind::Let { name, mutable, init, ty, .. } => {
                self.expr(init);
                let value = if *mutable { None } else { constant(init, ty) };
                let copied = value.is_some();
                self.declare(name, value);
                return !copied;
            }
            StmtKind::Assign { target, value, .. } => {
                match &mut target.kind {
                    ExprKind::Ident(_) => {}
                    ExprKind::Field { obj, .. } => self.expr(obj),
                    ExprKind::Index { obj, index } => {
                        self.expr(obj);
                        self.expr(index);
                    }
                    _ => self.expr(target),
                }
                self.expr(value);
            }
            StmtKind::Expr(e) | StmtKind::Fail(e) => self.expr(e),
            StmtKind::If { cond, then, els } => {
                self.expr(cond);
                self.block(then);
                if let Some(other) = els {
                    if !self.stmt(other) {
                        *els = None;
                    }
                }
                match cond.kind {
                    ExprKind::Bool(true) => {
                        let body = std::mem::replace(then, Block { stmts: Vec::new(), span: stmt.span });
                        replacement = Some(StmtKind::Block(body));
                    }
                    ExprKind::Bool(false) => match els.take() {
                        Some(other) => replacement = Some(other.kind),
                        None => return false,
                    },
                    _ => {}
                }
            }
            StmtKind::While { cond, body } => {
                self.expr(cond);
                self.block(body);
                if matches!(cond.kind, ExprKind::Bool(false)) {
                    return false;
                }
            }
            StmtKind::For { var, iter, body, .. } => {
                self.expr(iter);
                self.scopes.push(HashMap::new());
                self.declare(var, None);
                self.block(body);
                self.scopes.pop();
            }
            StmtKind::Return(value) => {
                if let Some(v) = value {
                    self.expr(v);
                }
            }
            StmtKind::Break | StmtKind::Continue => {}
            StmtKind::Fork(body) | StmtKind::Block(body) => self.block(body),
            StmtKind::Send { chan, value } => {
                self.expr(chan);
                self.expr(value);
            }
        }
        if let Some(kind) = replacement {
            stmt.kind = kind;
        }
        true
    }

    fn expr(&mut self, e: &mut Expr) {
        match &mut e.kind {
            ExprKind::Int(_) | ExprKind::Float(_) | ExprKind::Bool(_) => return,
            ExprKind::Ident(name) => {
                if let Some(value) = self.lookup(name) {
                    e.kind = value.into_kind();
                }
                return;
            }
            ExprKind::Str(parts) => {
                for part in parts.iter_mut() {
                    if let StrPart::Expr(inner) = part {
                        self.expr(inner);
                    }
                }
                merge_parts(parts);
                return;
            }
            ExprKind::List(items) => {
                for item in items {
                    self.expr(item);
                }
            }
            ExprKind::Map(entries) => {
                for (k, v) in entries {
                    self.expr(k);
                    self.expr(v);
                }
            }
            ExprKind::StructLit { fields, .. } => {
                for field in fields {
                    self.expr(&mut field.value);
                }
            }
            ExprKind::Unary { expr, .. } | ExprKind::Try(expr) | ExprKind::Recv(expr) => self.expr(expr),
            ExprKind::Binary { lhs, rhs, .. } => {
                self.expr(lhs);
                self.expr(rhs);
            }
            ExprKind::Call { callee, args } => {
                self.expr(callee);
                for arg in args {
                    self.expr(arg);
                }
            }
            ExprKind::Field { obj, .. } => self.expr(obj),
            ExprKind::Index { obj, index } => {
                self.expr(obj);
                self.expr(index);
            }
            ExprKind::Lambda { params, body, .. } => {
                self.scopes.push(HashMap::new());
                for p in params.iter() {
                    self.declare(&p.name, None);
                }
                self.stmts(&mut body.stmts);
                self.scopes.pop();
            }
            ExprKind::Or { expr, default } => {
                self.expr(expr);
                self.expr(default);
            }
            ExprKind::Catch { expr, name, body, .. } => {
                self.expr(expr);
                self.scopes.push(HashMap::new());
                self.declare(name, None);
                self.stmts(&mut body.stmts);
                self.scopes.pop();
            }
            ExprKind::ChanNew { cap, .. } => {
                if let Some(cap) = cap {
                    self.expr(cap);
                }
            }
            ExprKind::Range { lo, hi } => {
                self.expr(lo);
                self.expr(hi);
            }
        }

        match simplify(e) {
            Some(Simplified::Kind(kind)) => e.kind = kind,
            Some(side) => {
                // Replace the node by one of its operands, id included: the
                // checker's tables are keyed by the operand's own id.
                let placeholder = ExprKind::Bool(false);
                if let ExprKind::Binary { lhs, rhs, .. } = std::mem::replace(&mut e.kind, placeholder) {
                    *e = if matches!(side, Simplified::Lhs) { *lhs } else { *rhs };
                }
            }
            None => {}
        }
    }
}

/// Merges the literal pieces of an interpolated string: `"a{1 + 1}b"` is `"a2b"`.
fn merge_parts(parts: &mut Vec<StrPart>) {
    // A string inside a string is just more pieces.
    let mut flat = Vec::with_capacity(parts.len());
    for part in parts.drain(..) {
        match part {
            StrPart::Expr(Expr { kind: ExprKind::Str(inner), .. }) => flat.extend(inner),
            other => flat.push(other),
        }
    }
    let mut merged: Vec<StrPart> = Vec::with_capacity(flat.len());
    for part in flat {
        let text = match &part {
            StrPart::Lit(s) => Some(s.clone()),
            StrPart::Expr(e) => match &e.kind {
                ExprKind::Int(n) if n.unsigned_abs() <= MAX_SAFE => Some(n.to_string()),
                ExprKind::Bool(b) => Some(b.to_string()),
                _ => None,
            },
        };
        match (text, merged.last_mut()) {
            (Some(text), Some(StrPart::Lit(previous))) => previous.push_str(&text),
            (Some(text), _) => merged.push(StrPart::Lit(text)),
            (None, _) => merged.push(part),
        }
    }
    if merged.is_empty() {
        merged.push(StrPart::Lit(String::new()));
    }
    *parts = merged;
}

fn simplify(e: &Expr) -> Option<Simplified> {
    use ExprKind::*;
    let kind = match &e.kind {
        Unary { op: UnOp::Neg, expr } => match expr.kind {
            Int(n) if n.unsigned_abs() <= MAX_SAFE => Int(-n),
            Float(x) => Float(-x),
            _ => return None,
        },
        Unary { op: UnOp::Not, expr } => match expr.kind {
            Bool(b) => Bool(!b),
            _ => return None,
        },
        Binary { op, lhs, rhs } => return binary(*op, lhs, rhs),
        _ => return None,
    };
    Some(Simplified::Kind(kind))
}

fn binary(op: BinOp, lhs: &Expr, rhs: &Expr) -> Option<Simplified> {
    use ExprKind::*;
    let kind = match (&lhs.kind, &rhs.kind) {
        (Int(a), Int(b)) => int_op(op, *a, *b)?,
        (Float(a), Float(b)) => float_op(op, *a, *b)?,
        (Int(a), Float(b)) => float_op(op, *a as f64, *b)?,
        (Float(a), Int(b)) => float_op(op, *a, *b as f64)?,
        (Bool(a), Bool(b)) => Bool(match op {
            BinOp::And => *a && *b,
            BinOp::Or => *a || *b,
            BinOp::Eq => a == b,
            BinOp::NotEq => a != b,
            _ => return None,
        }),
        // With a known left side, `&&` and `||` are either decided or equal to
        // their right side. With a known right side that changes nothing, they
        // are equal to their left side.
        (Bool(true), _) if op == BinOp::And => return Some(Simplified::Rhs),
        (Bool(false), _) if op == BinOp::Or => return Some(Simplified::Rhs),
        (Bool(false), _) if op == BinOp::And => Bool(false),
        (Bool(true), _) if op == BinOp::Or => Bool(true),
        (_, Bool(true)) if op == BinOp::And => return Some(Simplified::Lhs),
        (_, Bool(false)) if op == BinOp::Or => return Some(Simplified::Lhs),
        _ => {
            let (a, b) = (plain_str(lhs)?, plain_str(rhs)?);
            match op {
                BinOp::Add if a.len() + b.len() <= 4096 => Str(vec![StrPart::Lit(format!("{a}{b}"))]),
                BinOp::Eq => Bool(a == b),
                BinOp::NotEq => Bool(a != b),
                // The targets only agree on the order of plain ASCII text.
                BinOp::Lt | BinOp::Le | BinOp::Gt | BinOp::Ge if a.is_ascii() && b.is_ascii() => Bool(match op {
                    BinOp::Lt => a < b,
                    BinOp::Le => a <= b,
                    BinOp::Gt => a > b,
                    _ => a >= b,
                }),
                _ => return None,
            }
        }
    };
    Some(Simplified::Kind(kind))
}

fn int_op(op: BinOp, a: i64, b: i64) -> Option<ExprKind> {
    if a.unsigned_abs() > MAX_SAFE || b.unsigned_abs() > MAX_SAFE {
        return None;
    }
    let value = match op {
        BinOp::Add => a.checked_add(b)?,
        BinOp::Sub => a.checked_sub(b)?,
        BinOp::Mul => a.checked_mul(b)?,
        // Dividing by zero must still fail when the program runs.
        BinOp::Div if b != 0 => a / b,
        BinOp::Mod if b != 0 => a % b,
        BinOp::Eq => return Some(ExprKind::Bool(a == b)),
        BinOp::NotEq => return Some(ExprKind::Bool(a != b)),
        BinOp::Lt => return Some(ExprKind::Bool(a < b)),
        BinOp::Le => return Some(ExprKind::Bool(a <= b)),
        BinOp::Gt => return Some(ExprKind::Bool(a > b)),
        BinOp::Ge => return Some(ExprKind::Bool(a >= b)),
        _ => return None,
    };
    (value.unsigned_abs() <= MAX_SAFE).then_some(ExprKind::Int(value))
}

fn float_op(op: BinOp, a: f64, b: f64) -> Option<ExprKind> {
    let value = match op {
        BinOp::Add => a + b,
        BinOp::Sub => a - b,
        BinOp::Mul => a * b,
        BinOp::Div if b != 0.0 => a / b,
        BinOp::Eq => return Some(ExprKind::Bool(a == b)),
        BinOp::NotEq => return Some(ExprKind::Bool(a != b)),
        BinOp::Lt => return Some(ExprKind::Bool(a < b)),
        BinOp::Le => return Some(ExprKind::Bool(a <= b)),
        BinOp::Gt => return Some(ExprKind::Bool(a > b)),
        BinOp::Ge => return Some(ExprKind::Bool(a >= b)),
        _ => return None,
    };
    value.is_finite().then_some(ExprKind::Float(value))
}
