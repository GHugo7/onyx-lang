//! Decides, before a function is compiled, which of its variables live in
//! processor registers instead of memory.
//!
//! Every use of a variable is counted, and a use inside a loop counts eight
//! times more for each level of nesting. The most used variables get the
//! registers; the others stay in the function's stack frame.

use super::asm::Reg;
use crate::ast::*;
use std::collections::{HashMap, HashSet};

/// Identifies a variable of a function: where it is declared in the source,
/// and which of the variables declared there it is.
pub type VarKey = (usize, u8);
/// The variable written in the source.
pub const NAMED: u8 = 0;
/// Hidden: the limit of a `for i in a..b` loop, or the position in a list loop.
pub const COUNTER: u8 = 1;
/// Hidden: the list that a `for x in list` loop walks.
pub const SUBJECT: u8 = 2;

pub struct Plan {
    pub regs: HashMap<VarKey, Reg>,
    /// Variables that are assigned to after their declaration.
    pub assigned: HashSet<VarKey>,
}

struct Candidate {
    key: VarKey,
    weight: u64,
    is_param: bool,
    assigned: bool,
}

struct Planner {
    scopes: Vec<HashMap<String, usize>>,
    vars: Vec<Candidate>,
    /// What one use is worth at the current loop depth.
    weight: u64,
}

pub fn plan(body: &Block, params: &[(String, VarKey)], registers: &[Reg]) -> Plan {
    let mut p = Planner { scopes: vec![HashMap::new()], vars: Vec::new(), weight: 1 };
    for (name, key) in params {
        p.declare(Some(name), *key, 0);
        p.vars.last_mut().unwrap().is_param = true;
    }
    for stmt in &body.stmts {
        p.stmt(stmt);
    }

    // A register has to be saved and restored by the function, and a parameter
    // has to be loaded into it: it only pays off for variables used a few times.
    let mut candidates: Vec<&Candidate> =
        p.vars.iter().filter(|v| v.weight >= if v.is_param { 4 } else { 3 }).collect();
    candidates.sort_by(|a, b| b.weight.cmp(&a.weight));
    Plan {
        regs: candidates.iter().zip(registers).map(|(v, r)| (v.key, *r)).collect(),
        assigned: p.vars.iter().filter(|v| v.assigned).map(|v| v.key).collect(),
    }
}

impl Planner {
    fn declare(&mut self, name: Option<&str>, key: VarKey, uses: u64) {
        self.vars.push(Candidate { key, weight: uses * self.weight, is_param: false, assigned: false });
        if let Some(name) = name {
            self.scopes.last_mut().unwrap().insert(name.to_string(), self.vars.len() - 1);
        }
    }

    fn touch(&mut self, name: &str, assigned: bool) {
        if let Some(&index) = self.scopes.iter().rev().find_map(|s| s.get(name)) {
            self.vars[index].weight += self.weight;
            self.vars[index].assigned |= assigned;
        }
    }

    fn in_loop(&mut self, f: impl FnOnce(&mut Self)) {
        let saved = self.weight;
        self.weight = (saved * 8).min(32768);
        f(self);
        self.weight = saved;
    }

    fn block(&mut self, block: &Block) {
        self.scopes.push(HashMap::new());
        for stmt in &block.stmts {
            self.stmt(stmt);
        }
        self.scopes.pop();
    }

    fn stmt(&mut self, stmt: &Stmt) {
        match &stmt.kind {
            StmtKind::Let { name, name_span, init, .. } => {
                self.expr(init);
                self.declare(Some(name), (name_span.start, NAMED), 1);
            }
            StmtKind::Assign { target, value, .. } => {
                match &target.kind {
                    ExprKind::Ident(name) => self.touch(name, true),
                    _ => self.expr(target),
                }
                self.expr(value);
            }
            StmtKind::Expr(e) | StmtKind::Fail(e) => self.expr(e),
            StmtKind::If { cond, then, els } => {
                self.expr(cond);
                self.block(then);
                if let Some(els) = els {
                    self.stmt(els);
                }
            }
            StmtKind::While { cond, body } => self.in_loop(|p| {
                p.expr(cond);
                p.block(body);
            }),
            StmtKind::For { var, var_span, iter, body } => {
                let at = var_span.start;
                self.scopes.push(HashMap::new());
                if let ExprKind::Range { lo, hi } = &iter.kind {
                    self.expr(lo);
                    self.expr(hi);
                    let constant_limit = matches!(hi.kind, ExprKind::Int(n) if i32::try_from(n).is_ok());
                    self.in_loop(|p| {
                        p.declare(Some(var), (at, NAMED), 3);
                        if !constant_limit {
                            p.declare(None, (at, COUNTER), 1);
                        }
                        p.block(body);
                    });
                } else {
                    self.expr(iter);
                    self.in_loop(|p| {
                        p.declare(None, (at, SUBJECT), 2);
                        p.declare(None, (at, COUNTER), 3);
                        p.declare(Some(var), (at, NAMED), 1);
                        p.block(body);
                    });
                }
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
    }

    fn expr(&mut self, e: &Expr) {
        match &e.kind {
            ExprKind::Int(_) | ExprKind::Float(_) | ExprKind::Bool(_) => {}
            ExprKind::Ident(name) => self.touch(name, false),
            ExprKind::Str(parts) => {
                for part in parts {
                    if let StrPart::Expr(inner) = part {
                        self.expr(inner);
                    }
                }
            }
            ExprKind::List(items) => items.iter().for_each(|item| self.expr(item)),
            ExprKind::Map(entries) => {
                for (k, v) in entries {
                    self.expr(k);
                    self.expr(v);
                }
            }
            ExprKind::StructLit { fields, .. } => fields.iter().for_each(|f| self.expr(&f.value)),
            ExprKind::Unary { expr, .. } | ExprKind::Try(expr) | ExprKind::Recv(expr) => self.expr(expr),
            ExprKind::Binary { lhs, rhs, .. } => {
                self.expr(lhs);
                self.expr(rhs);
            }
            ExprKind::Call { callee, args } => {
                self.expr(callee);
                args.iter().for_each(|arg| self.expr(arg));
            }
            ExprKind::Field { obj, .. } => self.expr(obj),
            ExprKind::Index { obj, index } => {
                self.expr(obj);
                self.expr(index);
            }
            ExprKind::Lambda { params, body, .. } => {
                // A lambda is a function of its own, planned separately: its
                // variables are followed here only to tell names apart.
                let first = self.vars.len();
                self.scopes.push(HashMap::new());
                for p in params {
                    self.declare(Some(&p.name), (p.span.start, NAMED), 0);
                }
                for stmt in &body.stmts {
                    self.stmt(stmt);
                }
                self.scopes.pop();
                for var in &mut self.vars[first..] {
                    var.weight = 0;
                }
            }
            ExprKind::Or { expr, default } => {
                self.expr(expr);
                self.expr(default);
            }
            ExprKind::Catch { expr, name, name_span, body } => {
                self.expr(expr);
                self.scopes.push(HashMap::new());
                self.declare(Some(name), (name_span.start, NAMED), 0);
                for stmt in &body.stmts {
                    self.stmt(stmt);
                }
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
    }
}
