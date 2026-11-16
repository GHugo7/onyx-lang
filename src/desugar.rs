//! Rewrites `match` with simpler statements, once the checker is done with it.
//!
//!     match shape {                   {
//!         Circle(r) {                     var $m1 = shape
//!             print(r)                    if __tag($m1) == 0 {
//!         }                                   var r = __field($m1, 0)
//!         Empty, Dot {          =>            print(r)
//!             print("small")              } else if __tag($m1) == 2 || __tag($m1) == 3 {
//!         }                                   print("small")
//!         else {                          } else {
//!             print("other")                  print("other")
//!         }                               }
//!     }                               }
//!
//! `__tag` gives the position of the variant an enum value is, and `__field`
//! one of the values it carries. A `match` on numbers, strings or booleans
//! compares with `==`. When there is no `else`, the checker made sure that
//! the cases cover everything: the last one then needs no test.
//!
//! The code generators never see a `match`.

use crate::ast::*;
use crate::checker::{Analysis, CallKind, Type};
use crate::diagnostics::Span;

pub fn desugar(program: &mut Program, an: &mut Analysis) {
    let next_id = an.types.keys().max().map_or(0, |id| id + 1);
    let mut d = Desugar { an, next_id, matches: 0 };
    for item in &mut program.items {
        match item {
            Item::Fn(f) => d.block(&mut f.body),
            Item::Struct(s) => s.methods.iter_mut().for_each(|m| d.block(&mut m.body)),
            Item::Check { body, .. } => d.block(body),
            Item::Global(stmt) => d.stmt(stmt),
            Item::Interface(_) | Item::Enum(_) | Item::Import { .. } => {}
        }
    }
}

struct Desugar<'a> {
    an: &'a mut Analysis,
    next_id: usize,
    matches: usize,
}

impl<'a> Desugar<'a> {
    fn node(&mut self, kind: ExprKind, ty: Type, span: Span) -> Expr {
        let id = self.next_id;
        self.next_id += 1;
        self.an.types.insert(id, ty);
        Expr { id, span, kind }
    }

    /// A call to one of the two helpers.
    fn helper(&mut self, name: &str, args: Vec<Expr>, ty: Type, span: Span) -> Expr {
        let callee = self.node(ExprKind::Ident(name.to_string()), Type::Unknown, span);
        let call = self.node(ExprKind::Call { callee: Box::new(callee), args }, ty, span);
        self.an.calls.insert(call.id, CallKind::Builtin(name.to_string()));
        call
    }

    fn block(&mut self, block: &mut Block) {
        for stmt in &mut block.stmts {
            self.stmt(stmt);
        }
    }

    fn stmt(&mut self, stmt: &mut Stmt) {
        let span = stmt.span;
        match &mut stmt.kind {
            StmtKind::Match { subject, arms, default } => {
                self.expr(subject);
                for arm in arms.iter_mut() {
                    self.block(&mut arm.body);
                }
                if let Some(body) = default {
                    self.block(body);
                }
                let placeholder = Expr { id: 0, span, kind: ExprKind::Bool(false) };
                let subject = std::mem::replace(subject, placeholder);
                let (arms, default) = (std::mem::take(arms), default.take());
                stmt.kind = self.rewrite(subject, arms, default, span);
            }
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
            StmtKind::While { cond: e, body } | StmtKind::For { iter: e, body, .. } => {
                self.expr(e);
                self.block(body);
            }
            StmtKind::Fork(body) | StmtKind::Block(body) => self.block(body),
            StmtKind::Send { chan, value } => {
                self.expr(chan);
                self.expr(value);
            }
        }
    }

    fn rewrite(&mut self, subject: Expr, arms: Vec<MatchArm>, default: Option<Block>, span: Span) -> StmtKind {
        let ty = self.an.types.get(&subject.id).cloned().unwrap_or(Type::Unknown);
        let variants = match &ty {
            Type::Enum(name) => self.an.enums.get(name).cloned().unwrap_or_default(),
            _ => Vec::new(),
        };
        self.matches += 1;
        let holder = format!("$m{}", self.matches);
        // Hidden variables get positions past any real source (see plan.rs).
        let position = usize::MAX / 8 + self.matches;
        let subject_span = subject.span;
        let keep = Stmt {
            span,
            kind: StmtKind::Let {
                name: holder.clone(),
                name_span: Span::new(position, position),
                mutable: false,
                ty: None,
                init: subject,
            },
        };

        // Built from the last case to the first, each one the `else` of the one before.
        let mut rest: Option<Stmt> = default.map(|body| Stmt { span: body.span, kind: StmtKind::Block(body) });
        for arm in arms.into_iter().rev() {
            let mut body = arm.body;
            let mut cond: Option<Expr> = None;
            for pattern in arm.patterns {
                let value = self.node(ExprKind::Ident(holder.clone()), ty.clone(), subject_span);
                let test = match pattern {
                    Pattern::Literal(literal) => {
                        let at = literal.span;
                        self.node(ExprKind::Binary { op: BinOp::Eq, lhs: Box::new(value), rhs: Box::new(literal) }, Type::Bool, at)
                    }
                    Pattern::Variant { name, span: at, bindings } => {
                        let index = variants.iter().position(|(n, _)| *n == name).unwrap_or(0);
                        // What the variant carries becomes variables at the start of the case.
                        let mut lets = Vec::new();
                        for (i, (binding, binding_span)) in bindings.into_iter().enumerate() {
                            if binding == "_" {
                                continue;
                            }
                            let field_ty = variants.get(index).and_then(|v| v.1.get(i)).cloned().unwrap_or(Type::Unknown);
                            let from = self.node(ExprKind::Ident(holder.clone()), ty.clone(), binding_span);
                            let which = self.node(ExprKind::Int(i as i64), Type::Int, binding_span);
                            let init = self.helper("__field", vec![from, which], field_ty, binding_span);
                            lets.push(Stmt {
                                span: binding_span,
                                kind: StmtKind::Let { name: binding, name_span: binding_span, mutable: true, ty: None, init },
                            });
                        }
                        if !lets.is_empty() {
                            lets.append(&mut body.stmts);
                            body.stmts = lets;
                        }
                        let tag = self.helper("__tag", vec![value], Type::Int, at);
                        let number = self.node(ExprKind::Int(index as i64), Type::Int, at);
                        self.node(ExprKind::Binary { op: BinOp::Eq, lhs: Box::new(tag), rhs: Box::new(number) }, Type::Bool, at)
                    }
                };
                cond = Some(match cond {
                    None => test,
                    Some(so_far) => {
                        let at = test.span;
                        self.node(ExprKind::Binary { op: BinOp::Or, lhs: Box::new(so_far), rhs: Box::new(test) }, Type::Bool, at)
                    }
                });
            }
            let body_span = body.span;
            rest = Some(match (rest, cond) {
                // The last case of a `match` without `else`: nothing else is possible.
                (None, _) | (_, None) => Stmt { span: body_span, kind: StmtKind::Block(body) },
                (Some(other), Some(cond)) => {
                    Stmt { span: body_span, kind: StmtKind::If { cond, then: body, els: Some(Box::new(other)) } }
                }
            });
        }
        let mut stmts = vec![keep];
        stmts.extend(rest);
        StmtKind::Block(Block { stmts, span })
    }

    /// Only looks for the blocks inside expressions: lambdas and `catch`.
    fn expr(&mut self, e: &mut Expr) {
        match &mut e.kind {
            ExprKind::Int(_) | ExprKind::Float(_) | ExprKind::Bool(_) | ExprKind::Ident(_) => {}
            ExprKind::Lambda { body, .. } => self.block(body),
            ExprKind::Catch { expr, body, .. } => {
                self.expr(expr);
                self.block(body);
            }
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
            ExprKind::Or { expr, default } => {
                self.expr(expr);
                self.expr(default);
            }
            ExprKind::ChanNew { cap, .. } => {
                if let Some(cap) = cap {
                    self.expr(cap);
                }
            }
        }
    }
}
