use gluon_lexer::Span;

#[derive(Debug, Clone, PartialEq)]
pub struct Ident(pub String, pub Span);

#[derive(Debug, Clone, PartialEq)]
pub enum Type {
    Scalar(ScalarType),
    ElementFormat(ElementFormat),
    Region(RegionType),
    Matrix(MatrixType),
    Refinement(Box<Type>, Predicate),
    Param(Ident),
}

#[derive(Debug, Clone, PartialEq)]
pub enum ScalarType {
    U8, U16, U32, U64,
    I8, I16, I32, I64,
    F32, F64,
    Bool,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ElementFormat {
    Raw,
    U8x4,
    F32x4,
    U16x4,
}

#[derive(Debug, Clone, PartialEq)]
pub struct RegionType {
    pub kind: Option<RegionKind>,
    pub dimensions: Vec<DimensionSpec>,
    pub format: ElementFormat,
    pub tier: Option<Tier>,
    pub access: Option<Access>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum RegionKind {
    Graphics,
    Input,
    Quantum,
    Neural,
    Dna,
}

#[derive(Debug, Clone, PartialEq)]
pub struct DimensionSpec {
    pub name: Ident,
    pub size: DimExpr,
    pub unit: String,
}

#[derive(Debug, Clone, PartialEq)]
pub enum DimExpr {
    Literal(u64, Span),
    Param(Ident),
}

#[derive(Debug, Clone, PartialEq)]
pub enum Tier {
    ShortTerm,
    LongTerm,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Access {
    ReadOnly,
    ReadWrite,
}

#[derive(Debug, Clone, PartialEq)]
pub struct MatrixType {
    pub from_dims: Vec<DimensionSpec>,
    pub to_dims: Vec<DimensionSpec>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Predicate {
    Compare(Expr, CmpOp, Expr),
    And(Box<Predicate>, Box<Predicate>),
    Or(Box<Predicate>, Box<Predicate>),
    Not(Box<Predicate>),
    Forall(Ident, Box<Type>, Box<Predicate>),
    Exists(Ident, Box<Type>, Box<Predicate>),
    Approx(Expr, Expr, Option<f64>),
    InRegion(Expr, Ident),
    IsFinite(Expr),
    Literal(bool),
}

#[derive(Debug, Clone, PartialEq)]
pub enum CmpOp {
    Eq, Neq, Lt, Gt, Lte, Gte,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Expr {
    IntLit(u64, Span),
    FloatLit(f64, Span),
    ColorLit(u32, Span),
    StringLit(String, Span),
    BoolLit(bool, Span),
    IntWithUnit(u64, String, Span),
    FloatWithUnit(f64, String, Span),
    Ident(Ident),
    RegionAccess {
        region: Ident,
        axes: Vec<AxisAccess>,
        span: Span,
    },
    ComponentAccess {
        object: Box<Expr>,
        component: String,
        span: Span,
    },
    BinaryOp(Box<Expr>, BinOp, Box<Expr>, Span),
    UnaryOp(UnaryOp, Box<Expr>, Span),
    Call(Ident, Vec<Expr>, Span),
    CreateRegion(RegionType, Span),
    MatrixLiteral(Vec<Vec<Expr>>, Span),
    ElementLit(Vec<(String, Expr)>, Span),
    Slice {
        region: Ident,
        slices: Vec<AxisSlice>,
        span: Span,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub enum BinOp {
    Add, Sub, Mul, Div, Mod, Pow,
    Eq, Neq, Lt, Gt, Lte, Gte,
    And, Or,
}

#[derive(Debug, Clone, PartialEq)]
pub enum UnaryOp {
    Neg, Not,
}

#[derive(Debug, Clone, PartialEq)]
pub enum AxisAccess {
    Index(Expr),
    Range(Option<Expr>, Option<Expr>),
    All,
}

#[derive(Debug, Clone, PartialEq)]
pub enum AxisSlice {
    Index(Ident, Expr),
    Range(Ident, Option<Expr>, Option<Expr>),
    All(Ident),
}

#[derive(Debug, Clone, PartialEq)]
pub struct Module {
    pub items: Vec<Item>,
    pub span: Span,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Item {
    RegionDecl(RegionDecl),
    ProcessDecl(ProcessDecl),
    TemporalSpec(TemporalSpecData),
}

#[derive(Debug, Clone, PartialEq)]
pub struct RegionDecl {
    pub name: Ident,
    pub region_type: RegionType,
    pub invariants: Vec<Predicate>,
    pub span: Span,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ProcessDecl {
    pub name: Ident,
    pub reads: Vec<(Ident, Option<Access>)>,
    pub writes: Vec<(Ident, Option<Access>)>,
    pub privates: Vec<PrivateDecl>,
    pub constrains: Vec<(Ident, Predicate)>,
    pub requires: Vec<Predicate>,
    pub ensures: Vec<Predicate>,
    pub temporal_invariants: Vec<TemporalExpr>,
    pub react_blocks: Vec<ReactBlock>,
    pub span: Span,
}

#[derive(Debug, Clone, PartialEq)]
pub struct PrivateDecl {
    pub name: Ident,
    pub type_ann: Option<Type>,
    pub init: Option<Expr>,
    pub span: Span,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ReactBlock {
    When(WhenBlock),
    Every(EveryBlock),
    Call(CallBlock),
}

#[derive(Debug, Clone, PartialEq)]
pub struct WhenBlock {
    pub triggers: Vec<Ident>,
    pub body: Vec<Statement>,
    pub span: Span,
}

#[derive(Debug, Clone, PartialEq)]
pub struct EveryBlock {
    pub duration: f64,
    pub unit: String,
    pub body: Vec<Statement>,
    pub span: Span,
}

#[derive(Debug, Clone, PartialEq)]
pub struct CallBlock {
    pub name: Ident,
    pub params: Vec<(Ident, Type)>,
    pub return_type: Option<Type>,
    pub body: Vec<Statement>,
    pub span: Span,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Statement {
    Let(LetStmt),
    Assign(AssignStmt),
    RegionWrite(RegionWriteStmt),
    If(IfStmt),
    For(ForStmt),
    Return(Option<Expr>, Span),
    Assert(Predicate, Span),
    Assume(Predicate, Span),
    Expr(Expr),
    Spawn(SpawnStmt),
    Grant(GrantStmt),
    Revoke(RevokeStmt),
    Migrate(MigrateStmt),
    Builtin(BuiltinStmt),
    Kill(Option<Ident>, Span),
}

#[derive(Debug, Clone, PartialEq)]
pub struct LetStmt {
    pub name: Ident,
    pub type_ann: Option<Type>,
    pub init: Expr,
    pub span: Span,
}

#[derive(Debug, Clone, PartialEq)]
pub struct AssignStmt {
    pub name: Ident,
    pub value: Expr,
    pub span: Span,
}

#[derive(Debug, Clone, PartialEq)]
pub struct RegionWriteStmt {
    pub region: Ident,
    pub axes: Vec<AxisAccess>,
    pub value: Expr,
    pub span: Span,
}

#[derive(Debug, Clone, PartialEq)]
pub struct IfStmt {
    pub condition: Expr,
    pub then_body: Vec<Statement>,
    pub else_ifs: Vec<(Expr, Vec<Statement>)>,
    pub else_body: Option<Vec<Statement>>,
    pub span: Span,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ForStmt {
    pub vars: Vec<Ident>,
    pub iterable: Expr,
    pub body: Vec<Statement>,
    pub span: Span,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SpawnStmt {
    pub process_name: Ident,
    pub reads: Vec<(Ident, Option<Access>)>,
    pub writes: Vec<(Ident, Option<Access>)>,
    pub span: Span,
}

#[derive(Debug, Clone, PartialEq)]
pub struct GrantStmt {
    pub region: Ident,
    pub access: Access,
    pub target: Ident,
    pub span: Span,
}

#[derive(Debug, Clone, PartialEq)]
pub struct RevokeStmt {
    pub region: Ident,
    pub target: Ident,
    pub span: Span,
}

#[derive(Debug, Clone, PartialEq)]
pub struct MigrateStmt {
    pub region: Ident,
    pub from_tier: Tier,
    pub to_tier: Tier,
    pub span: Span,
}

#[derive(Debug, Clone, PartialEq)]
pub enum BuiltinStmt {
    Project {
        source: Ident,
        transform: Ident,
        target: Ident,
        span: Span,
    },
    Blend {
        source: Ident,
        over: Ident,
        into: Option<Ident>,
        span: Span,
    },
    Evolve {
        state: Ident,
        hamiltonian: Ident,
        dt: Expr,
        span: Span,
    },
    Convolve {
        kernel: Ident,
        over: Ident,
        into: Option<Ident>,
        activation: Option<String>,
        span: Span,
    },
    Matmul {
        input: Ident,
        through: Ident,
        into: Ident,
        span: Span,
    },
    Pool {
        activation: Ident,
        stride: Expr,
        into: Ident,
        span: Span,
    },
    Clear {
        region: Ident,
        color: Expr,
        span: Span,
    },
    Swap {
        a: Ident,
        b: Ident,
        span: Span,
    },
    Persist {
        region: Ident,
        span: Span,
    },
    Copy {
        source: Ident,
        target: Ident,
        span: Span,
    },
    Reshape {
        source: Ident,
        into: Ident,
        span: Span,
    },
    Fill {
        region: Ident,
        color: Expr,
        radius: Option<Expr>,
        shadow: Option<Expr>,
        span: Span,
    },
    DrawText {
        region: Ident,
        text: Expr,
        pos: (Expr, Expr),
        font: Expr,
        size: Expr,
        color: Expr,
        bold: bool,
        center: bool,
        span: Span,
    },
    Compose {
        direction: ComposeDirection,
        parent: Ident,
        children: Vec<ComposeChild>,
        span: Span,
    },
    Softmax {
        input: Ident,
        into: Ident,
        span: Span,
    },
    Relu {
        input: Ident,
        in_place: bool,
        span: Span,
    },
    Measure {
        state: Ident,
        into: Ident,
        span: Span,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub struct TemporalSpecData {
    pub invariants: Vec<TemporalExpr>,
    pub span: Span,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ComposeDirection {
    Vertical,
    Horizontal,
    Grid,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ComposeChild {
    pub region: Ident,
    pub x: Expr,
    pub y: Expr,
    pub weight: Option<Expr>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum TemporalExpr {
    Always(InnerTemporal, Span),
    Eventually(InnerTemporal, Span),
    Until(Box<TemporalExpr>, Box<TemporalExpr>, Span),
    BoundedEventually(InnerTemporal, Expr, String, Span),
    Next(InnerTemporal, Span),
}

#[derive(Debug, Clone, PartialEq)]
pub enum InnerTemporal {
    Written(Ident),
    BeingWritten(Ident),
    BeingScanned(Ident),
    Implies(Box<InnerTemporal>, Box<InnerTemporal>),
    And(Box<InnerTemporal>, Box<InnerTemporal>),
    Or(Box<InnerTemporal>, Box<InnerTemporal>),
    Not(Box<InnerTemporal>),
    EveryProcessEventuallyActivated,
    Grouped(Box<InnerTemporal>),
}