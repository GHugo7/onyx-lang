//! Works out what every lambda captures.
//!
//! A lambda may use the variables of the function it is written in, and
//! keeps working after that function has returned:
//!
//!     fn counter() -> fn() -> int {
//!         var n = 0
//!         return fn() -> int {
//!             n += 1
//!             return n
//!         }
//!     }
//!
//! Natively a lambda is compiled as a function of its own, and its value is
//! a small object, the closure, that holds the address of that code and the
//! variables it uses. This pass finds those variables.
//!
//! A captured variable that never changes after its declaration is simply
//! copied into the closure. One that is assigned to (like `n` above) has to
//! be shared between the function and its lambdas: it moves into a box, a
//! one-field object that both sides point to. The pass rewrites the program
//! for that:
//!
//!     var n = 0           var n = $box{v: 0}
//!     n += 1        =>    n.v += 1
//!     return n            return n.v
//!
//! so that afterwards every captured variable is one that never changes, and
//! the code generator only has to copy values.

use crate::ast::*;
use crate::checker::{Analysis, StructInfo, Type};
use crate::diagnostics::Span;
use std::collections::{HashMap, HashSet};

/// A variable, identified by where it is declared (`self` by its method's name).
type Key = (usize, bool);

/// Variables made by this pass get positions past any real source.
const BOX_POSITIONS: usize = usize::MAX / 4;

pub fn capture(program: &mut Program, an: &mut Analysis) {
    let mut finder = Finder { an, scopes: Vec::new(), frames: Vec::new(), depth_of: HashMap::new(), assigned: HashSet::new(), captured: HashSet::new(), found: HashMap::new() };
    for item in &program.items {
        match item {
            Item::Fn(f) => finder.function(&f.params, None, &f.body),
            Item::Struct(s) => {
                for m in &s.methods {
                    finder.function(&m.params, Some(m.name_span.start), &m.body);
                }
            }
            Item::Global(stmt) => {
                finder.scopes.push(HashMap::new());
                finder.frames.push(Vec::new());
                finder.stmt(stmt);
                finder.frames.pop();
                finder.scopes.pop();
            }
            _ => {}
        }
    }
    let boxed: HashSet<Key> = finder.captured.intersection(&finder.assigned).copied().collect();
    let found = finder.found;

    let mut captures = HashMap::new();
    let mut types: HashMap<Key, Type> = HashMap::new();
    for (lambda, vars) in found {
        for (key, _, ty) in &vars {
            types.insert(*key, ty.clone());
        }
        let list: Vec<(String, Type)> = vars
            .into_iter()
            .map(|(key, name, ty)| if boxed.contains(&key) { (name, Type::Struct(box_name(&ty))) } else { (name, ty) })
            .collect();
        captures.insert(lambda, list);
    }
    an.captures = captures;
    if boxed.is_empty() {
        return;
    }

    let next_id = an.types.keys().max().map_or(0, |id| id + 1);
    let mut boxer = Boxer { an, boxed, types, scopes: Vec::new(), next_id, made: 0, before: None };
    for item in &mut program.items {
        match item {
            Item::Fn(f) => boxer.function(&f.params, None, &mut f.body),
            Item::Struct(s) => {
                for m in &mut s.methods {
                    boxer.function(&m.params, Some(m.name_span.start), &mut m.body);
                }
            }
            Item::Global(stmt) => {
                boxer.scopes.push(HashMap::new());
                boxer.stmt(stmt);
                boxer.scopes.pop();
            }
            _ => {}
        }
    }
}

fn box_name(ty: &Type) -> String {
    format!("$box<{ty}>")
}

// ---- first walk: who uses what ----

struct Finder<'a> {
    an: &'a Analysis,
    scopes: Vec<HashMap<String, Key>>,
    /// One entry per function being walked, innermost last: what it captures.
    frames: Vec<Vec<(Key, String, Type)>>,
    /// The function (as an index in `frames`) each variable belongs to.
    depth_of: HashMap<Key, usize>,
    assigned: HashSet<Key>,
    captured: HashSet<Key>,
    found: HashMap<usize, Vec<(Key, String, Type)>>,
}

impl<'a> Finder<'a> {
    fn declare(&mut self, name: &str, key: Key) {
        self.depth_of.insert(key, self.frames.len() - 1);
        self.scopes.last_mut().unwrap().insert(name.to_string(), key);
    }

    fn touch(&mut self, e: &Expr, name: &str, assigned: bool) {
        let Some(&key) = self.scopes.iter().rev().find_map(|s| s.get(name)) else { return };
        if assigned {
            self.assigned.insert(key);
        }
        let home = self.depth_of[&key];
        if home + 1 < self.frames.len() {
            // Used in a lambda: that lambda captures it, and so does every
            // lambda around it up to the function that owns the variable.
            self.captured.insert(key);
            let ty = self.an.types.get(&e.id).cloned().unwrap_or(Type::Unknown);
            for frame in &mut self.frames[home + 1..] {
                if !frame.iter().any(|(k, _, _)| *k == key) {
                    frame.push((key, name.to_string(), ty.clone()));
                }
            }
        }
    }

    fn function(&mut self, params: &[Param], this: Option<usize>, body: &Block) {
        self.scopes.push(HashMap::new());
        self.frames.push(Vec::new());
        if let Some(position) = this {
            self.declare("self", (position, true));
        }
        for p in params {
            self.declare(&p.name, (p.span.start, false));
        }
        for stmt in &body.stmts {
            self.stmt(stmt);
        }
        self.frames.pop();
        self.scopes.pop();
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
                self.declare(name, (name_span.start, false));
            }
            StmtKind::Assign { target, value, .. } => {
                match &target.kind {
                    ExprKind::Ident(name) => self.touch(target, name, true),
                    _ => self.expr(target),
                }
                self.expr(value);
            }
            StmtKind::Expr(e) | StmtKind::Fail(e) | StmtKind::Return(Some(e)) => self.expr(e),
            StmtKind::Return(None) | StmtKind::Break | StmtKind::Continue => {}
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
            StmtKind::For { var, var_span, iter, body } => {
                self.expr(iter);
                self.scopes.push(HashMap::new());
                self.declare(var, (var_span.start, false));
                self.block(body);
                self.scopes.pop();
            }
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
            ExprKind::Ident(name) => self.touch(e, name, false),
            ExprKind::Str(parts) => {
                for part in parts {
                    if let StrPart::Expr(inner) = part {
                        self.expr(inner);
                    }
                }
            }
            ExprKind::List(items) => items.iter().for_each(|item| self.expr(item)),
            ExprKind::Map(entries) => {
                for (key, value) in entries {
                    self.expr(key);
                    self.expr(value);
                }
            }
            ExprKind::StructLit { fields, .. } => fields.iter().for_each(|f| self.expr(&f.value)),
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
                args.iter().for_each(|arg| self.expr(arg));
            }
            ExprKind::Lambda { params, body, .. } => {
                self.scopes.push(HashMap::new());
                self.frames.push(Vec::new());
                for p in params {
                    self.declare(&p.name, (p.span.start, false));
                }
                for stmt in &body.stmts {
                    self.stmt(stmt);
                }
                let captured = self.frames.pop().unwrap();
                self.scopes.pop();
                self.found.insert(e.id, captured);
            }
            ExprKind::Or { expr, default } => {
                self.expr(expr);
                self.expr(default);
            }
            ExprKind::Catch { expr, name, name_span, body } => {
                self.expr(expr);
                self.scopes.push(HashMap::new());
                self.declare(name, (name_span.start, false));
                self.block(body);
                self.scopes.pop();
            }
            ExprKind::ChanNew { cap, .. } => {
                if let Some(cap) = cap {
                    self.expr(cap);
                }
            }
        }
    }
}

// ---- second walk: variables that move into a box ----

struct Boxer<'a> {
    an: &'a mut Analysis,
    boxed: HashSet<Key>,
    /// The types of the captured variables.
    types: HashMap<Key, Type>,
    scopes: Vec<HashMap<String, Key>>,
    next_id: usize,
    made: usize,
    /// A statement to put in front of the one being rewritten.
    before: Option<Stmt>,
}

impl<'a> Boxer<'a> {
    fn node(&mut self, kind: ExprKind, ty: Type, span: Span) -> Expr {
        let id = self.next_id;
        self.next_id += 1;
        self.an.types.insert(id, ty);
        Expr { id, span, kind }
    }

    /// The type of the box for values of type `ty`, declared on first use.
    fn box_type(&mut self, ty: &Type) -> Type {
        let name = box_name(ty);
        self.an
            .structs
            .entry(name.clone())
            .or_insert_with(|| StructInfo { fields: vec![("v".to_string(), ty.clone())], methods: HashMap::new() });
        Type::Struct(name)
    }

    /// `$box{v: value}`
    fn wrap(&mut self, value: Expr) -> Expr {
        let ty = self.an.types.get(&value.id).cloned().unwrap_or(Type::Unknown);
        let span = value.span;
        let Type::Struct(name) = self.box_type(&ty) else { unreachable!() };
        let field = FieldInit { name: "v".to_string(), name_span: span, value };
        self.node(ExprKind::StructLit { name: name.clone(), name_span: span, fields: vec![field] }, Type::Struct(name), span)
    }

    fn is_boxed(&self, name: &str) -> bool {
        self.scopes.iter().rev().find_map(|s| s.get(name)).is_some_and(|key| self.boxed.contains(key))
    }

    /// Parameters that are boxed get their box when the function starts:
    /// `var p = $box{v: p}`.
    fn params(&mut self, params: &[Param], this: Option<usize>, body: &mut Block) {
        if let Some(position) = this {
            self.scopes.last_mut().unwrap().insert("self".to_string(), (position, true));
        }
        let mut boxes = Vec::new();
        for p in params {
            let key = (p.span.start, false);
            self.scopes.last_mut().unwrap().insert(p.name.clone(), key);
            if self.boxed.contains(&key) {
                let Some(ty) = self.types.get(&key).cloned() else { continue };
                let value = self.node(ExprKind::Ident(p.name.clone()), ty, p.span);
                let init = self.wrap(value);
                self.made += 1;
                let position = BOX_POSITIONS + self.made;
                boxes.push(Stmt {
                    span: p.span,
                    kind: StmtKind::Let { name: p.name.clone(), name_span: Span::new(position, position), mutable: false, ty: None, init },
                });
            }
        }
        self.stmts(&mut body.stmts);
        if !boxes.is_empty() {
            boxes.append(&mut body.stmts);
            body.stmts = boxes;
        }
    }

    fn function(&mut self, params: &[Param], this: Option<usize>, body: &mut Block) {
        self.scopes.push(HashMap::new());
        self.params(params, this, body);
        self.scopes.pop();
    }

    fn block(&mut self, block: &mut Block) {
        self.scopes.push(HashMap::new());
        self.stmts(&mut block.stmts);
        self.scopes.pop();
    }

    fn stmts(&mut self, stmts: &mut Vec<Stmt>) {
        let mut out = Vec::with_capacity(stmts.len());
        for mut stmt in stmts.drain(..) {
            self.stmt(&mut stmt);
            if let Some(first) = self.before.take() {
                out.push(first);
            }
            out.push(stmt);
        }
        *stmts = out;
    }

    fn stmt(&mut self, stmt: &mut Stmt) {
        match &mut stmt.kind {
            StmtKind::Let { name, name_span, init, ty, .. } => {
                self.expr(init);
                let key = (name_span.start, false);
                if self.boxed.contains(&key) {
                    let mut value = std::mem::replace(init, Expr { id: 0, span: init.span, kind: ExprKind::Bool(false) });
                    if let ExprKind::Catch { .. } = value.kind {
                        // A `catch` has to stay at the root of a statement:
                        //     var x$v = call() catch err { ... }
                        //     var x = $box{v: x$v}
                        let (value_ty, span) = (self.an.types.get(&value.id).cloned().unwrap_or(Type::Unknown), value.span);
                        self.made += 1;
                        let position = BOX_POSITIONS + self.made;
                        let temp = format!("{name}$v");
                        self.before = Some(Stmt {
                            span,
                            kind: StmtKind::Let { name: temp.clone(), name_span: Span::new(position, position), mutable: false, ty: None, init: value },
                        });
                        value = self.node(ExprKind::Ident(temp), value_ty, span);
                    }
                    *init = self.wrap(value);
                    *ty = None;
                }
                self.scopes.last_mut().unwrap().insert(name.clone(), key);
            }
            StmtKind::Assign { target, value, .. } => {
                self.expr(target);
                self.expr(value);
            }
            StmtKind::Expr(e) | StmtKind::Fail(e) | StmtKind::Return(Some(e)) => self.expr(e),
            StmtKind::Return(None) | StmtKind::Break | StmtKind::Continue => {}
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
            StmtKind::For { var, var_span, iter, body } => {
                self.expr(iter);
                self.scopes.push(HashMap::new());
                self.scopes.last_mut().unwrap().insert(var.clone(), (var_span.start, false));
                self.block(body);
                self.scopes.pop();
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
            ExprKind::Int(_) | ExprKind::Float(_) | ExprKind::Bool(_) => {}
            ExprKind::Ident(name) => {
                if self.is_boxed(name) {
                    // The variable now names its box: read (or write) what is inside.
                    let ty = self.an.types.get(&e.id).cloned().unwrap_or(Type::Unknown);
                    let holder = self.box_type(&ty);
                    let obj = self.node(ExprKind::Ident(name.clone()), holder, e.span);
                    e.kind = ExprKind::Field { obj: Box::new(obj), name: "v".to_string(), name_span: e.span };
                }
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
            ExprKind::Lambda { params, body, .. } => {
                let params = params.clone();
                self.function(&params, None, body);
            }
            ExprKind::Or { expr, default } => {
                self.expr(expr);
                self.expr(default);
            }
            ExprKind::Catch { expr, name, name_span, body } => {
                self.expr(expr);
                self.scopes.push(HashMap::new());
                self.scopes.last_mut().unwrap().insert(name.clone(), (name_span.start, false));
                self.block(body);
                self.scopes.pop();
            }
            ExprKind::ChanNew { cap, .. } => {
                if let Some(cap) = cap {
                    self.expr(cap);
                }
            }
        }
    }
}
