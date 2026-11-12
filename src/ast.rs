//! The abstract syntax tree produced by the parser.

use crate::diagnostics::Span;

#[derive(Debug, Clone)]
pub struct Program {
    pub items: Vec<Item>,
}

#[derive(Debug, Clone)]
pub enum Item {
    Fn(FnDecl),
    Struct(StructDecl),
    Interface(InterfaceDecl),
    /// A top-level `var` / `const`.
    Global(Stmt),
    /// A `check "name" { ... }` test block.
    Check { name: String, body: Block },
    /// `import "path"` or `import "path" as alias`.
    Import { path: String, alias: Option<String>, span: Span },
}

#[derive(Debug, Clone)]
pub struct Param {
    pub name: String,
    pub ty: TypeExpr,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub struct FnDecl {
    pub name: String,
    pub name_span: Span,
    pub has_self: bool,
    pub params: Vec<Param>,
    pub ret: Option<TypeExpr>,
    pub fallible: bool,
    pub body: Block,
}

#[derive(Debug, Clone)]
pub struct FieldDecl {
    pub name: String,
    pub ty: TypeExpr,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub struct StructDecl {
    pub name: String,
    pub name_span: Span,
    pub fields: Vec<FieldDecl>,
    pub methods: Vec<FnDecl>,
}

#[derive(Debug, Clone)]
pub struct MethodSig {
    pub name: String,
    pub name_span: Span,
    pub params: Vec<Param>,
    pub ret: Option<TypeExpr>,
    pub fallible: bool,
}

#[derive(Debug, Clone)]
pub struct InterfaceDecl {
    pub name: String,
    pub name_span: Span,
    pub methods: Vec<MethodSig>,
}

#[derive(Debug, Clone)]
pub struct TypeExpr {
    pub kind: TypeKind,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub enum TypeKind {
    Named(String),
    List(Box<TypeExpr>),
    Map(Box<TypeExpr>, Box<TypeExpr>),
    Chan(Box<TypeExpr>),
    Fn { params: Vec<TypeExpr>, ret: Option<Box<TypeExpr>>, fallible: bool },
}

#[derive(Debug, Clone)]
pub struct Block {
    pub stmts: Vec<Stmt>,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub struct Stmt {
    pub kind: StmtKind,
    pub span: Span,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum AssignOp {
    Set,
    Add,
    Sub,
    Mul,
    Div,
}

#[derive(Debug, Clone)]
pub enum StmtKind {
    Let { name: String, name_span: Span, mutable: bool, ty: Option<TypeExpr>, init: Expr },
    Assign { target: Expr, op: AssignOp, value: Expr },
    Expr(Expr),
    If { cond: Expr, then: Block, els: Option<Box<Stmt>> },
    While { cond: Expr, body: Block },
    For { var: String, var_span: Span, iter: Expr, body: Block },
    Return(Option<Expr>),
    Break,
    Continue,
    Fail(Expr),
    Fork(Block),
    Send { chan: Expr, value: Expr },
    Block(Block),
}

#[derive(Debug, Clone)]
pub struct Expr {
    /// Unique per program; keys the type checker's side tables.
    pub id: usize,
    pub span: Span,
    pub kind: ExprKind,
}

#[derive(Debug, Clone)]
pub enum StrPart {
    Lit(String),
    Expr(Expr),
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum UnOp {
    Neg,
    Not,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum BinOp {
    Add,
    Sub,
    Mul,
    Div,
    Mod,
    Eq,
    NotEq,
    Lt,
    Le,
    Gt,
    Ge,
    And,
    Or,
}

impl BinOp {
    pub fn symbol(self) -> &'static str {
        match self {
            BinOp::Add => "+",
            BinOp::Sub => "-",
            BinOp::Mul => "*",
            BinOp::Div => "/",
            BinOp::Mod => "%",
            BinOp::Eq => "==",
            BinOp::NotEq => "!=",
            BinOp::Lt => "<",
            BinOp::Le => "<=",
            BinOp::Gt => ">",
            BinOp::Ge => ">=",
            BinOp::And => "&&",
            BinOp::Or => "||",
        }
    }
}

#[derive(Debug, Clone)]
pub struct FieldInit {
    pub name: String,
    pub name_span: Span,
    pub value: Expr,
}

#[derive(Debug, Clone)]
pub enum ExprKind {
    Int(i64),
    Float(f64),
    Bool(bool),
    Str(Vec<StrPart>),
    Ident(String),
    List(Vec<Expr>),
    Map(Vec<(Expr, Expr)>),
    StructLit { name: String, name_span: Span, fields: Vec<FieldInit> },
    Unary { op: UnOp, expr: Box<Expr> },
    Binary { op: BinOp, lhs: Box<Expr>, rhs: Box<Expr> },
    Call { callee: Box<Expr>, args: Vec<Expr> },
    Field { obj: Box<Expr>, name: String, name_span: Span },
    Index { obj: Box<Expr>, index: Box<Expr> },
    Lambda { params: Vec<Param>, ret: Option<TypeExpr>, fallible: bool, body: Block },
    /// `call()?`
    Try(Box<Expr>),
    /// `call() or default`
    Or { expr: Box<Expr>, default: Box<Expr> },
    /// `call() catch err { ... }`
    Catch { expr: Box<Expr>, name: String, name_span: Span, body: Block },
    /// `<-ch`
    Recv(Box<Expr>),
    /// `chan<T>()` or `chan<T>(capacity)`
    ChanNew { elem: TypeExpr, cap: Option<Box<Expr>> },
    /// `lo..hi`
    Range { lo: Box<Expr>, hi: Box<Expr> },
}
