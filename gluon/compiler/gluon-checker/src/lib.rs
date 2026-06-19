use std::collections::HashMap;
use std::fmt;

use gluon_lexer::Span;
use gluon_parser::ast::*;
use gluon_resolver::{ResolvedModule, ResolvedItem};

pub mod dimensions;
pub mod types;

pub use dimensions::DimensionChecker;
pub use types::{Type, TypeChecker, TypeError, expr_type, expr_span};

#[derive(Debug, Clone)]
pub struct CheckError {
    pub message: String,
    pub span: Span,
}

impl fmt::Display for CheckError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "type error at {}: {}", self.span, self.message)
    }
}

impl std::error::Error for CheckError {}

pub type CheckResult<T> = Result<T, Vec<CheckError>>;

pub struct Checker {
    type_checker: TypeChecker,
    dim_checker: DimensionChecker,
    errors: Vec<CheckError>,
}

impl Checker {
    pub fn new() -> Self {
        Checker {
            type_checker: TypeChecker::new(),
            dim_checker: DimensionChecker::new(),
            errors: Vec::new(),
        }
    }

    pub fn check(&mut self, module: &Module, resolved: &ResolvedModule) -> CheckResult<()> {
        for (item, resolved_item) in module.items.iter().zip(resolved.items.iter()) {
            match (item, resolved_item) {
                (Item::RegionDecl(decl), ResolvedItem::RegionDecl(_)) => {
                    self.check_region_decl(decl);
                }
                (Item::ProcessDecl(proc), ResolvedItem::ProcessDecl(_)) => {
                    self.check_process_decl(proc);
                }
                (Item::TemporalSpec(_), ResolvedItem::TemporalSpec(_)) => {}
                _ => {}
            }
        }
        if self.errors.is_empty() {
            Ok(())
        } else {
            Err(self.errors.clone())
        }
    }

    fn check_region_decl(&mut self, decl: &RegionDecl) {
        for dim in &decl.region_type.dimensions {
            let dim_type = self.type_checker.check_dim_expr(&dim.size);
            if !dim_type.is_integer() {
                self.errors.push(CheckError {
                    message: format!("dimension '{}' size must be an integer type, got {:?}", dim.name.0, dim_type),
                    span: dim.name.1.clone(),
                });
            }
            if let DimExpr::Literal(val, span) = &dim.size {
                if *val == 0 {
                    self.errors.push(CheckError {
                        message: format!("dimension '{}' size must be positive, got 0", dim.name.0),
                        span: span.clone(),
                    });
                }
            }
            if !dim.unit.is_empty() {
                let dim_obj = self.dim_checker.unit_to_dimension(&dim.unit);
                if dim_obj.is_error() {
                    self.errors.push(CheckError {
                        message: format!("unknown unit '{}' for dimension '{}'", dim.unit, dim.name.0),
                        span: dim.name.1.clone(),
                    });
                }
            }
        }
        for inv in &decl.invariants {
            self.check_predicate(inv);
        }
    }

    fn check_process_decl(&mut self, proc: &ProcessDecl) {
        let mut local_types: HashMap<String, Type> = HashMap::new();
        for (name, access) in &proc.reads {
            local_types.insert(name.0.clone(), Type::RegionRef(access.clone()));
        }
        for (name, access) in &proc.writes {
            local_types.entry(name.0.clone()).or_insert(Type::RegionRef(access.clone()));
        }
        for private in &proc.privates {
            let private_type = private.type_ann.as_ref().map_or(Type::Inferred, |t| self.type_checker.ast_type_to_type(t));
            if let Some(ref init) = private.init {
                let init_type = self.type_checker.check_expr(init);
                if !private_type.is_compatible_with(&init_type) && !private_type.is_inferred() {
                    self.errors.push(CheckError {
                        message: format!(
                            "private '{}' declared as {:?} but initialized with incompatible type",
                            private.name.0, private_type
                        ),
                        span: private.name.1.clone(),
                    });
                }
            }
            local_types.insert(private.name.0.clone(), private_type);
        }
        for block in &proc.react_blocks {
            self.check_react_block(block, &local_types);
        }
        for pred in &proc.requires {
            self.check_predicate(pred);
        }
        for pred in &proc.ensures {
            self.check_predicate(pred);
        }
        for (_, pred) in &proc.constrains {
            self.check_predicate(pred);
        }
    }

    fn check_react_block(&mut self, block: &ReactBlock, local_types: &HashMap<String, Type>) {
        match block {
            ReactBlock::When(wb) => {
                self.check_statements(&wb.body, local_types);
            }
            ReactBlock::Every(eb) => {
                self.check_statements(&eb.body, local_types);
            }
            ReactBlock::Call(cb) => {
                self.check_statements(&cb.body, local_types);
            }
        }
    }

    fn check_statements(&mut self, stmts: &[Statement], local_types: &HashMap<String, Type>) {
        for stmt in stmts {
            match stmt {
                Statement::Let(let_stmt) => {
                    let init_type = self.type_checker.check_expr(&let_stmt.init);
                    let declared_type = let_stmt.type_ann.as_ref().map_or(Type::Inferred, |t| self.type_checker.ast_type_to_type(t));
                    if !declared_type.is_compatible_with(&init_type) && !declared_type.is_inferred() {
                        self.errors.push(CheckError {
                            message: format!(
                                "let '{}' declared as {:?} but init has type {:?}",
                                let_stmt.name.0, declared_type, init_type
                            ),
                            span: let_stmt.name.1.clone(),
                        });
                    }
                }
                Statement::Assign(assign) => {
                    let value_type = self.type_checker.check_expr(&assign.value);
                    if let Some(expected) = local_types.get(&assign.name.0) {
                        if !expected.is_compatible_with(&value_type) {
                            self.errors.push(CheckError {
                                message: format!(
                                    "cannot assign value of type {:?} to '{}' of type {:?}",
                                    value_type, assign.name.0, expected
                                ),
                                span: assign.name.1.clone(),
                            });
                        }
                    }
                }
                Statement::RegionWrite(rw) => {
                    self.type_checker.check_expr(&rw.value);
                }
                Statement::If(if_stmt) => {
                    let cond_type = self.type_checker.check_expr(&if_stmt.condition);
                    if !cond_type.is_bool() {
                        self.errors.push(CheckError {
                            message: format!("if condition must be bool, got {:?}", cond_type),
                            span: if_stmt.span.clone(),
                        });
                    }
                    self.check_statements(&if_stmt.then_body, local_types);
                    if let Some(ref else_body) = if_stmt.else_body {
                        self.check_statements(else_body, local_types);
                    }
                }
                Statement::For(for_stmt) => {
                    self.type_checker.check_expr(&for_stmt.iterable);
                    self.check_statements(&for_stmt.body, local_types);
                }
                Statement::Expr(expr) => {
                    self.type_checker.check_expr(expr);
                }
                Statement::Assert(_, _) | Statement::Assume(_, _) => {}
                Statement::Return(_, _) | Statement::Kill(_, _) => {}
                Statement::Spawn(_) | Statement::Grant(_) | Statement::Revoke(_) | Statement::Migrate(_) => {}
                Statement::Builtin(_) => {}
            }
        }
    }

    fn check_predicate(&mut self, pred: &Predicate) {
        match pred {
            Predicate::Compare(left, _, right) => {
                let left_type = self.type_checker.check_expr(left);
                let right_type = self.type_checker.check_expr(right);
                if !left_type.is_compatible_with(&right_type) {
                    self.errors.push(CheckError {
                        message: format!("comparison between incompatible types: {:?} and {:?}", left_type, right_type),
                        span: expr_span(left).clone(),
                    });
                }
            }
            Predicate::And(a, b) | Predicate::Or(a, b) => {
                self.check_predicate(a);
                self.check_predicate(b);
            }
            Predicate::Not(a) => {
                self.check_predicate(a);
            }
            Predicate::Forall(_, _, p) | Predicate::Exists(_, _, p) => {
                self.check_predicate(p);
            }
            Predicate::Approx(left, right, _) => {
                self.type_checker.check_expr(left);
                self.type_checker.check_expr(right);
            }
            Predicate::InRegion(expr, _) => {
                self.type_checker.check_expr(expr);
            }
            Predicate::IsFinite(expr) => {
                self.type_checker.check_expr(expr);
            }
            Predicate::Literal(_) => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gluon_lexer::Lexer;
    use gluon_parser::Parser;
    use gluon_resolver::Resolver;

    fn check_source(source: &str) -> CheckResult<()> {
        let tokens = Lexer::new(source).tokenize().expect("lexing should succeed");
        let module = Parser::new(tokens).parse_module().expect("parsing should succeed");
        let mut resolver = Resolver::new();
        let resolved = resolver.resolve(&module).expect("resolution should succeed");
        let mut checker = Checker::new();
        checker.check(&module, &resolved)
    }

    #[test]
    fn test_check_simple_region() {
        let source = "region fb: region[x: 720px] of U8x4 @ ShortTerm @ ReadWrite;";
        assert!(check_source(source).is_ok());
    }

    #[test]
    fn test_check_simple_process() {
        let source = r#"
region fb: region[x: 720px] of U8x4 @ ShortTerm @ ReadWrite;
process renderer:
    reads fb @ ReadOnly;
    when fb changes:
        fb[0] := 0;
    end
"#;
        assert!(check_source(source).is_ok());
    }
}