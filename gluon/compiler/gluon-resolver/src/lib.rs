use std::collections::HashMap;
use std::fmt;

use gluon_lexer::Span;
use gluon_parser::ast::*;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum SymbolKind {
    Region,
    Process,
    Variable,
    Axis,
    Type,
    Function,
}

impl fmt::Display for SymbolKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SymbolKind::Region => write!(f, "region"),
            SymbolKind::Process => write!(f, "process"),
            SymbolKind::Variable => write!(f, "variable"),
            SymbolKind::Axis => write!(f, "axis"),
            SymbolKind::Type => write!(f, "type"),
            SymbolKind::Function => write!(f, "function"),
        }
    }
}

#[derive(Debug, Clone)]
pub struct Symbol {
    pub name: String,
    pub kind: SymbolKind,
    pub span: Span,
    pub decl: Option<usize>,
}

#[derive(Debug, Clone)]
pub struct Scope {
    symbols: HashMap<String, Symbol>,
    parent: Option<Box<Scope>>,
}

impl Scope {
    pub fn new() -> Self {
        Scope {
            symbols: HashMap::new(),
            parent: None,
        }
    }

    pub fn with_parent(parent: Scope) -> Self {
        Scope {
            symbols: HashMap::new(),
            parent: Some(Box::new(parent)),
        }
    }

    pub fn define(&mut self, name: &str, kind: SymbolKind, span: Span) -> Result<(), ResolveError> {
        if self.symbols.contains_key(name) {
            Err(ResolveError {
                message: format!("{} '{}' is already defined in this scope", kind, name),
                span,
            })
        } else {
            self.symbols.insert(
                name.to_string(),
                Symbol {
                    name: name.to_string(),
                    kind,
                    span,
                    decl: None,
                },
            );
            Ok(())
        }
    }

    pub fn lookup(&self, name: &str) -> Option<&Symbol> {
        if let Some(sym) = self.symbols.get(name) {
            Some(sym)
        } else if let Some(ref parent) = self.parent {
            parent.lookup(name)
        } else {
            None
        }
    }
}

#[derive(Debug, Clone)]
pub struct ResolveError {
    pub message: String,
    pub span: Span,
}

impl fmt::Display for ResolveError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "resolve error at {}: {}", self.span, self.message)
    }
}

impl std::error::Error for ResolveError {}

pub type ResolveResult<T> = Result<T, Vec<ResolveError>>;

#[derive(Debug, Clone)]
pub struct ResolvedModule {
    pub items: Vec<ResolvedItem>,
    pub scope: Scope,
}

#[derive(Debug, Clone)]
pub enum ResolvedItem {
    RegionDecl(ResolvedRegionDecl),
    ProcessDecl(ResolvedProcessDecl),
    TemporalSpec(TemporalSpecData),
}

#[derive(Debug, Clone)]
pub struct ResolvedRegionDecl {
    pub name: String,
    pub region_type: RegionType,
    pub invariants: Vec<Predicate>,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub struct ResolvedProcessDecl {
    pub name: String,
    pub reads: Vec<(String, Option<Access>)>,
    pub writes: Vec<(String, Option<Access>)>,
    pub privates: Vec<PrivateDecl>,
    pub constrains: Vec<(String, Predicate)>,
    pub requires: Vec<Predicate>,
    pub ensures: Vec<Predicate>,
    pub temporal_invariants: Vec<TemporalExpr>,
    pub react_blocks: Vec<ReactBlock>,
    pub span: Span,
}

pub struct Resolver {
    errors: Vec<ResolveError>,
}

impl Resolver {
    pub fn new() -> Self {
        Resolver { errors: Vec::new() }
    }

    pub fn resolve(&mut self, module: &Module) -> ResolveResult<ResolvedModule> {
        let mut scope = Scope::new();
        let mut resolved_items = Vec::new();

        for item in &module.items {
            match item {
                Item::RegionDecl(decl) => {
                    if let Err(e) = scope.define(&decl.name.0, SymbolKind::Region, decl.name.1) {
                        self.errors.push(e);
                    }
                    resolved_items.push(ResolvedItem::RegionDecl(ResolvedRegionDecl {
                        name: decl.name.0.clone(),
                        region_type: decl.region_type.clone(),
                        invariants: decl.invariants.clone(),
                        span: decl.span.clone(),
                    }));
                }
                Item::ProcessDecl(proc) => {
                    if let Err(e) = scope.define(&proc.name.0, SymbolKind::Process, proc.name.1) {
                        self.errors.push(e);
                    }
                    let resolved_proc = self.resolve_process(proc, &scope);
                    resolved_items.push(ResolvedItem::ProcessDecl(resolved_proc));
                }
                Item::TemporalSpec(spec) => {
                    resolved_items.push(ResolvedItem::TemporalSpec(spec.clone()));
                }
            }
        }

        if self.errors.is_empty() {
            Ok(ResolvedModule {
                items: resolved_items,
                scope,
            })
        } else {
            Err(self.errors.clone())
        }
    }

    fn resolve_process(&mut self, proc: &ProcessDecl, parent_scope: &Scope) -> ResolvedProcessDecl {
        let mut scope = Scope::with_parent(parent_scope.clone());

        for (name, _access) in &proc.reads {
            if let Err(e) = scope.define(&name.0, SymbolKind::Variable, name.1) {
                self.errors.push(e);
            }
        }
        for (name, _access) in &proc.writes {
            if scope.lookup(&name.0).is_none() {
                if let Err(e) = scope.define(&name.0, SymbolKind::Variable, name.1) {
                    self.errors.push(e);
                }
            }
        }
        for private in &proc.privates {
            if let Err(e) = scope.define(&private.name.0, SymbolKind::Variable, private.name.1) {
                self.errors.push(e);
            }
        }

        self.resolve_react_blocks(&proc.react_blocks, &scope);

        ResolvedProcessDecl {
            name: proc.name.0.clone(),
            reads: proc.reads.iter().map(|(n, a)| (n.0.clone(), a.clone())).collect(),
            writes: proc.writes.iter().map(|(n, a)| (n.0.clone(), a.clone())).collect(),
            privates: proc.privates.clone(),
            constrains: proc.constrains.iter().map(|(n, p)| (n.0.clone(), p.clone())).collect(),
            requires: proc.requires.clone(),
            ensures: proc.ensures.clone(),
            temporal_invariants: proc.temporal_invariants.clone(),
            react_blocks: proc.react_blocks.clone(),
            span: proc.span.clone(),
        }
    }

    fn resolve_react_blocks(&mut self, blocks: &[ReactBlock], scope: &Scope) {
        for block in blocks {
            match block {
                ReactBlock::When(wb) => {
                    for trigger in &wb.triggers {
                        if scope.lookup(&trigger.0).is_none() {
                            self.errors.push(ResolveError {
                                message: format!("unknown region '{}' in when trigger", trigger.0),
                                span: trigger.1.clone(),
                            });
                        }
                    }
                    self.resolve_statements(&wb.body, scope);
                }
                ReactBlock::Every(eb) => {
                    self.resolve_statements(&eb.body, scope);
                }
                ReactBlock::Call(cb) => {
                    self.resolve_statements(&cb.body, scope);
                }
            }
        }
    }

    fn resolve_statements(&mut self, stmts: &[Statement], scope: &Scope) {
        for stmt in stmts {
            match stmt {
                Statement::Let(let_stmt) => {
                    self.resolve_expr(&let_stmt.init, scope);
                }
                Statement::Assign(assign_stmt) => {
                    if scope.lookup(&assign_stmt.name.0).is_none() {
                        self.errors.push(ResolveError {
                            message: format!("unknown variable '{}'", assign_stmt.name.0),
                            span: assign_stmt.name.1.clone(),
                        });
                    }
                    self.resolve_expr(&assign_stmt.value, scope);
                }
                Statement::RegionWrite(rw) => {
                    if scope.lookup(&rw.region.0).is_none() {
                        self.errors.push(ResolveError {
                            message: format!("unknown region '{}'", rw.region.0),
                            span: rw.region.1.clone(),
                        });
                    }
                    self.resolve_expr(&rw.value, scope);
                }
                Statement::If(if_stmt) => {
                    self.resolve_expr(&if_stmt.condition, scope);
                    self.resolve_statements(&if_stmt.then_body, scope);
                    if let Some(ref else_body) = if_stmt.else_body {
                        self.resolve_statements(else_body, scope);
                    }
                    for (_, body) in &if_stmt.else_ifs {
                        self.resolve_statements(body, scope);
                    }
                }
                Statement::For(for_stmt) => {
                    let mut inner_scope = Scope::with_parent(scope.clone());
                    for var in &for_stmt.vars {
                        let _ = inner_scope.define(&var.0, SymbolKind::Variable, var.1.clone());
                    }
                    self.resolve_expr(&for_stmt.iterable, scope);
                    self.resolve_statements(&for_stmt.body, &inner_scope);
                }
                Statement::Spawn(spawn) => {
                    if scope.lookup(&spawn.process_name.0).is_none() {
                        self.errors.push(ResolveError {
                            message: format!("unknown process '{}'", spawn.process_name.0),
                            span: spawn.process_name.1.clone(),
                        });
                    }
                }
                Statement::Grant(grant) => {
                    if scope.lookup(&grant.region.0).is_none() {
                        self.errors.push(ResolveError {
                            message: format!("unknown region '{}'", grant.region.0),
                            span: grant.region.1.clone(),
                        });
                    }
                }
                Statement::Revoke(revoke) => {
                    if scope.lookup(&revoke.region.0).is_none() {
                        self.errors.push(ResolveError {
                            message: format!("unknown region '{}'", revoke.region.0),
                            span: revoke.region.1.clone(),
                        });
                    }
                }
                Statement::Migrate(migrate) => {
                    if scope.lookup(&migrate.region.0).is_none() {
                        self.errors.push(ResolveError {
                            message: format!("unknown region '{}'", migrate.region.0),
                            span: migrate.region.1.clone(),
                        });
                    }
                }
                Statement::Kill(_, _) => {}
                Statement::Return(_, _) => {}
                Statement::Assert(_, _) => {}
                Statement::Assume(_, _) => {}
                Statement::Expr(expr) => {
                    self.resolve_expr(expr, scope);
                }
                Statement::Builtin(_) => {}
            }
        }
    }

    fn resolve_expr(&mut self, expr: &Expr, scope: &Scope) {
        match expr {
            Expr::Ident(ident) => {
                if scope.lookup(&ident.0).is_none() {
                    self.errors.push(ResolveError {
                        message: format!("unknown identifier '{}'", ident.0),
                        span: ident.1.clone(),
                    });
                }
            }
            Expr::BinaryOp(left, _, right, _) => {
                self.resolve_expr(left, scope);
                self.resolve_expr(right, scope);
            }
            Expr::UnaryOp(_, right, _) => {
                self.resolve_expr(right, scope);
            }
            Expr::RegionAccess { region, axes, span: _ } => {
                if scope.lookup(&region.0).is_none() {
                    self.errors.push(ResolveError {
                        message: format!("unknown region '{}'", region.0),
                        span: region.1.clone(),
                    });
                }
                for axis in axes {
                    match axis {
                        AxisAccess::Index(e) => {
                            self.resolve_expr(e, scope);
                        }
                        AxisAccess::Range(start, end) => {
                            if let Some(s) = start { self.resolve_expr(s, scope); }
                            if let Some(e) = end { self.resolve_expr(e, scope); }
                        }
                        AxisAccess::All => {}
                    }
                }
            }
            Expr::ComponentAccess { object, component: _, span: _ } => {
                self.resolve_expr(object, scope);
            }
            Expr::Call(_, args, _) => {
                for arg in args {
                    self.resolve_expr(arg, scope);
                }
            }
            Expr::Slice { region, slices: _, span: _ } => {
                if scope.lookup(&region.0).is_none() {
                    self.errors.push(ResolveError {
                        message: format!("unknown region '{}'", region.0),
                        span: region.1.clone(),
                    });
                }
            }
            Expr::CreateRegion(_, _) => {}
            Expr::IntLit(_, _) | Expr::FloatLit(_, _) | Expr::ColorLit(_, _) => {}
            Expr::StringLit(_, _) | Expr::BoolLit(_, _) => {}
            Expr::IntWithUnit(_, _, _) | Expr::FloatWithUnit(_, _, _) => {}
            Expr::MatrixLiteral(rows, _) => {
                for row in rows {
                    for elem in row {
                        self.resolve_expr(elem, scope);
                    }
                }
            }
            Expr::ElementLit(pairs, _) => {
                for (_, val) in pairs {
                    self.resolve_expr(val, scope);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gluon_lexer::Lexer;
    use gluon_parser::Parser;

    fn resolve_source(source: &str) -> Result<ResolvedModule, Vec<ResolveError>> {
        let tokens = Lexer::new(source).tokenize().expect("lexing should succeed");
        let module = Parser::new(tokens).parse_module().expect("parsing should succeed");
        let mut resolver = Resolver::new();
        resolver.resolve(&module)
    }

    #[test]
    fn test_resolve_simple_region() {
        let source = "region fb: region[x: 720px, y: 1440px, z: 1layer, t: 2frames] of U8x4 @ ShortTerm @ ReadWrite;";
        let result = resolve_source(source);
        assert!(result.is_ok());
        let module = result.unwrap();
        assert_eq!(module.items.len(), 1);
    }

    #[test]
    fn test_resolve_simple_process() {
        let source = r#"
process hello:
    reads input_data @ ReadOnly;
    writes output_data;
    when input_data changes:
        output_data[0] := input_data[0];
    end
"#;
        let result = resolve_source(source);
        assert!(result.is_ok());
    }

    #[test]
    fn test_resolve_unknown_region_reference() {
        let source = r#"
process broken:
    reads nonexistent @ ReadOnly;
    writes output_data;
    when nonexistent changes:
        output_data[0] := 0;
    end
"#;
        // This should still parse but the resolver should not error
        // because reads declarations define the names within the process scope
        let result = resolve_source(source);
        assert!(result.is_ok());
    }
}