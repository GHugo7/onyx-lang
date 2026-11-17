// The syntax tree that the parser builds.
//
// Positions are numbers of bytes from the start of the source. Where the
// Rust compiler has a value that may be absent, there is a list here, with
// no element or one.

struct Name {
    text: string
    start: int
    end: int
}

struct TypeExpr {
    kind: TypeKind
    start: int
    end: int
}

enum TypeKind {
    Named(string)
    List(TypeExpr)
    Map(key: TypeExpr, value: TypeExpr)
    Chan(TypeExpr)
    Weak(TypeExpr)
    Fn(params: [TypeExpr], ret: [TypeExpr], fallible: bool)
}

struct Param {
    name: string
    ty: TypeExpr
    start: int
    end: int
}

struct FnDecl {
    name: string
    name_start: int
    name_end: int
    has_self: bool
    params: [Param]
    ret: [TypeExpr]
    fallible: bool
    body: Block
}

struct FieldDecl {
    name: string
    ty: TypeExpr
    start: int
    end: int
}

struct StructDecl {
    name: string
    name_start: int
    name_end: int
    fields: [FieldDecl]
    methods: [FnDecl]
}

struct MethodSig {
    name: string
    name_start: int
    name_end: int
    params: [Param]
    ret: [TypeExpr]
    fallible: bool
}

struct InterfaceDecl {
    name: string
    name_start: int
    name_end: int
    methods: [MethodSig]
}

struct VariantDecl {
    name: string
    start: int
    end: int
    fields: [TypeExpr]
}

struct EnumDecl {
    name: string
    name_start: int
    name_end: int
    variants: [VariantDecl]
}

enum Item {
    Fn(FnDecl)
    Struct(StructDecl)
    Interface(InterfaceDecl)
    Enum(EnumDecl)
    // A top-level `var` / `const`.
    Global(Stmt)
    // A `check "name" \{ ... \}` test block.
    Check(name: string, body: Block)
    // `import "path"` or `import "path" as alias`.
    Import(path: string, alias: [string], start: int, end: int)
}

struct Program {
    items: [Item]
    // The first expression id that is still free.
    next_id: int
}

struct Block {
    stmts: [Stmt]
    start: int
    end: int
}

struct Stmt {
    kind: StmtKind
    start: int
    end: int
}

enum AssignOp {
    Set
    Add
    Sub
    Mul
    Div
}

struct MatchArm {
    patterns: [Pattern]
    body: Block
}

enum Pattern {
    Literal(Expr)
    Variant(name: string, start: int, end: int, bindings: [Name])
}

enum StmtKind {
    Let(name: string, name_start: int, name_end: int, mutable: bool, ty: [TypeExpr], init: Expr)
    Assign(target: Expr, op: AssignOp, value: Expr)
    Expr(Expr)
    If(cond: Expr, then: Block, els: [Stmt])
    While(cond: Expr, body: Block)
    For(name: string, name_start: int, name_end: int, iter: Expr, body: Block)
    Return([Expr])
    Break
    Continue
    Fail(Expr)
    Fork(Block)
    Send(channel: Expr, value: Expr)
    Block(Block)
    Match(subject: Expr, arms: [MatchArm], default: [Block])
}

struct Expr {
    // Unique per program; the type checker keeps what it learns under it.
    id: int
    start: int
    end: int
    kind: ExprKind
}

enum StrPart {
    Lit(string)
    Code(Expr)
}

enum UnOp {
    Neg
    Not
}

enum BinOp {
    Add
    Sub
    Mul
    Div
    Mod
    Eq
    NotEq
    Lt
    Le
    Gt
    Ge
    And
    Or
}

struct FieldInit {
    name: string
    name_start: int
    name_end: int
    value: Expr
}

struct Entry {
    key: Expr
    value: Expr
}

enum ExprKind {
    Int(int)
    Float(float)
    Bool(bool)
    Str([StrPart])
    Ident(string)
    List([Expr])
    Map([Entry])
    StructLit(name: string, name_start: int, name_end: int, fields: [FieldInit])
    Unary(op: UnOp, expr: Expr)
    Binary(op: BinOp, lhs: Expr, rhs: Expr)
    Call(callee: Expr, args: [Expr])
    Field(obj: Expr, name: string, name_start: int, name_end: int)
    Index(obj: Expr, index: Expr)
    Lambda(params: [Param], ret: [TypeExpr], fallible: bool, body: Block)
    // `call()?`
    Try(Expr)
    // `call() or default`
    Or(expr: Expr, default: Expr)
    // `call() catch err \{ ... \}`
    Catch(expr: Expr, name: string, name_start: int, name_end: int, body: Block)
    // `<-ch`
    Recv(Expr)
    // `chan<T>()` or `chan<T>(capacity)`
    ChanNew(elem: TypeExpr, cap: [Expr])
    // `lo..hi`
    Range(lo: Expr, hi: Expr)
}

// ---- for the passes that rewrite the tree ----

// A new node with the same id, position and content as `e`: what `e` was,
// before it is overwritten.
fn copy_of(e: Expr) -> Expr {
    return Expr{id: e.id, start: e.start, end: e.end, kind: e.kind}
}

// Makes `e` the node `other` is, id included, where `e` stands in the tree.
fn overwrite(e: Expr, other: Expr) {
    e.id = other.id
    e.start = other.start
    e.end = other.end
    e.kind = other.kind
}
