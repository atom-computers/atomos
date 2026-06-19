use std::collections::HashMap;
use std::fmt;

use gluon_lexer::Span;
use gluon_parser::ast::*;

use crate::dimensions::Dimension;

#[derive(Debug, Clone, PartialEq)]
pub enum Type {
    U8, U16, U32, U64,
    I8, I16, I32, I64,
    F32, F64,
    Bool,
    String,
    Unit,
    RegionRef(Option<Access>),
    Matrix(MatrixTypeInfo),
    Element(ElementTypeInfo),
    Dimensional(Box<Type>, Dimension),
    Inferred,
    Error,
}

#[derive(Debug, Clone, PartialEq)]
pub struct MatrixTypeInfo {
    pub rows: usize,
    pub cols: usize,
    pub scalar_type: Box<Type>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ElementTypeInfo {
    pub format: ElementFormat,
    pub count: usize,
}

impl Type {
    pub fn is_integer(&self) -> bool {
        matches!(self, Type::U8 | Type::U16 | Type::U32 | Type::U64 | Type::I8 | Type::I16 | Type::I32 | Type::I64)
    }

    pub fn is_numeric(&self) -> bool {
        self.is_integer() || matches!(self, Type::F32 | Type::F64)
    }

    pub fn is_bool(&self) -> bool {
        matches!(self, Type::Bool)
    }

    pub fn is_compatible_with(&self, other: &Type) -> bool {
        match (self, other) {
            (Type::Inferred, _) | (_, Type::Inferred) => true,
            (Type::Error, _) | (_, Type::Error) => true,
            (Type::Dimensional(a, da), Type::Dimensional(b, db)) => {
                a.is_compatible_with(b) && da == db
            }
            (Type::Dimensional(inner, _), other) | (other, Type::Dimensional(inner, _)) => {
                inner.is_compatible_with(other)
            }
            (a, b) => a == b || (a.is_numeric() && b.is_numeric()),
        }
    }

    pub fn is_inferred(&self) -> bool {
        matches!(self, Type::Inferred)
    }

    pub fn is_region(&self) -> bool {
        matches!(self, Type::RegionRef(_))
    }
}

pub fn expr_type(expr: &Expr) -> Type {
    match expr {
        Expr::IntLit(_, _) => Type::U32,
        Expr::FloatLit(_, _) => Type::F64,
        Expr::ColorLit(_, _) => Type::Element(ElementTypeInfo {
            format: ElementFormat::U8x4,
            count: 1,
        }),
        Expr::StringLit(_, _) => Type::String,
        Expr::BoolLit(_, _) => Type::Bool,
        Expr::IntWithUnit(_, unit, _) => Type::Dimensional(Box::new(Type::U32), Dimension::from_unit(unit)),
        Expr::FloatWithUnit(_, unit, _) => Type::Dimensional(Box::new(Type::F64), Dimension::from_unit(unit)),
        _ => Type::Inferred,
    }
}

pub fn expr_span(expr: &Expr) -> &Span {
    match expr {
        Expr::IntLit(_, s) => s,
        Expr::FloatLit(_, s) => s,
        Expr::ColorLit(_, s) => s,
        Expr::StringLit(_, s) => s,
        Expr::BoolLit(_, s) => s,
        Expr::IntWithUnit(_, _, s) => s,
        Expr::FloatWithUnit(_, _, s) => s,
        Expr::Ident(i) => &i.1,
        Expr::RegionAccess { span: s, .. } => s,
        Expr::ComponentAccess { span: s, .. } => s,
        Expr::BinaryOp(_, _, _, s) => s,
        Expr::UnaryOp(_, _, s) => s,
        Expr::Call(_, _, s) => s,
        Expr::CreateRegion(_, s) => s,
        Expr::MatrixLiteral(_, s) => s,
        Expr::ElementLit(_, s) => s,
        Expr::Slice { span: s, .. } => s,
    }
}

pub struct TypeChecker {
    builtin_types: HashMap<String, Type>,
}

impl TypeChecker {
    pub fn new() -> Self {
        let mut builtin_types = HashMap::new();
        builtin_types.insert("sin".to_string(), Type::F64);
        builtin_types.insert("cos".to_string(), Type::F64);
        builtin_types.insert("tan".to_string(), Type::F64);
        builtin_types.insert("abs".to_string(), Type::F64);
        builtin_types.insert("min".to_string(), Type::F64);
        builtin_types.insert("max".to_string(), Type::F64);
        builtin_types.insert("clamp".to_string(), Type::F64);
        builtin_types.insert("sqrt".to_string(), Type::F64);
        builtin_types.insert("pow".to_string(), Type::F64);
        builtin_types.insert("exp".to_string(), Type::F64);
        builtin_types.insert("log".to_string(), Type::F64);
        TypeChecker { builtin_types }
    }

    pub fn check_expr(&mut self, expr: &Expr) -> Type {
        match expr {
            Expr::IntLit(_, _) => Type::U32,
            Expr::FloatLit(_, _) => Type::F64,
            Expr::ColorLit(_, _) => Type::Element(ElementTypeInfo {
                format: ElementFormat::U8x4,
                count: 1,
            }),
            Expr::StringLit(_, _) => Type::String,
            Expr::BoolLit(_, _) => Type::Bool,
            Expr::IntWithUnit(_, unit, _) => Type::Dimensional(Box::new(Type::U32), Dimension::from_unit(unit)),
            Expr::FloatWithUnit(_, unit, _) => Type::Dimensional(Box::new(Type::F64), Dimension::from_unit(unit)),
            Expr::Ident(_) => Type::Inferred,
            Expr::BinaryOp(left, op, right, _) => {
                let left_type = self.check_expr(left);
                let right_type = self.check_expr(right);
                self.binary_result_type(&left_type, op, &right_type)
            }
            Expr::UnaryOp(op, inner, _) => {
                let inner_type = self.check_expr(inner);
                match op {
                    UnaryOp::Neg => {
                        if inner_type.is_numeric() { inner_type } else { Type::Error }
                    }
                    UnaryOp::Not => {
                        if inner_type.is_bool() { Type::Bool } else { Type::Error }
                    }
                }
            }
            Expr::RegionAccess { .. } => Type::Inferred,
            Expr::ComponentAccess { .. } => Type::Inferred,
            Expr::Call(name, args, _) => {
                for arg in args {
                    self.check_expr(arg);
                }
                self.builtin_types.get(&name.0).cloned().unwrap_or(Type::Inferred)
            }
            Expr::CreateRegion(region_type, _) => Type::RegionRef(region_type.access.clone()),
            Expr::MatrixLiteral(rows, _) => {
                let rows_count = rows.len();
                let cols_count = rows.first().map_or(0, |r| r.len());
                let scalar_type = rows.first().and_then(|r| r.first()).map_or(Type::Inferred, |e| self.check_expr(e));
                Type::Matrix(MatrixTypeInfo {
                    rows: rows_count,
                    cols: cols_count,
                    scalar_type: Box::new(scalar_type),
                })
            }
            Expr::ElementLit(pairs, _) => {
                for (_, val) in pairs {
                    self.check_expr(val);
                }
                Type::Inferred
            }
            Expr::Slice { .. } => Type::Inferred,
        }
    }

    fn binary_result_type(&mut self, left: &Type, op: &BinOp, right: &Type) -> Type {
        match op {
            BinOp::Eq | BinOp::Neq | BinOp::Lt | BinOp::Gt | BinOp::Lte | BinOp::Gte => Type::Bool,
            BinOp::And | BinOp::Or => {
                if left.is_bool() && right.is_bool() { Type::Bool } else { Type::Error }
            }
            BinOp::Add | BinOp::Sub | BinOp::Mul | BinOp::Div | BinOp::Mod | BinOp::Pow => {
                match (left, right) {
                    (Type::Dimensional(lt, ld), Type::Dimensional(_, rd)) => {
                        let result_dim = match op {
                            BinOp::Mul => Dimension::mul_dims(ld, rd),
                            BinOp::Div => Dimension::div_dims(ld, rd),
                            BinOp::Add | BinOp::Sub => {
                                if ld == rd { Ok(ld.clone()) } else { Ok(Dimension::error()) }
                            }
                            _ => Ok(Dimension::error()),
                        };
                        result_dim.map_or(Type::Error, |d| Type::Dimensional(lt.clone(), d))
                    }
                    (Type::Dimensional(lt, ld), other) | (other, Type::Dimensional(lt, ld)) => {
                        if matches!(op, BinOp::Mul | BinOp::Div) {
                            if other.is_numeric() {
                                Type::Dimensional(lt.clone(), ld.clone())
                            } else {
                                Type::Error
                            }
                        } else {
                            Type::Dimensional(lt.clone(), ld.clone())
                        }
                    }
                    _ => {
                        if left.is_numeric() && right.is_numeric() { left.clone() } else { Type::Error }
                    }
                }
            }
        }
    }

    pub fn check_dim_expr(&self, dim_expr: &DimExpr) -> Type {
        match dim_expr {
            DimExpr::Literal(_, _) => Type::U64,
            DimExpr::Param(_) => Type::Inferred,
        }
    }

    pub fn ast_type_to_type(&self, ast_type: &gluon_parser::ast::Type) -> Type {
        match ast_type {
            gluon_parser::ast::Type::Scalar(s) => match s {
                ScalarType::U8 => Type::U8,
                ScalarType::U16 => Type::U16,
                ScalarType::U32 => Type::U32,
                ScalarType::U64 => Type::U64,
                ScalarType::I8 => Type::I8,
                ScalarType::I16 => Type::I16,
                ScalarType::I32 => Type::I32,
                ScalarType::I64 => Type::I64,
                ScalarType::F32 => Type::F32,
                ScalarType::F64 => Type::F64,
                ScalarType::Bool => Type::Bool,
            },
            gluon_parser::ast::Type::ElementFormat(fmt) => Type::Element(ElementTypeInfo {
                format: fmt.clone(),
                count: 1,
            }),
            gluon_parser::ast::Type::Region(rt) => Type::RegionRef(rt.access.clone()),
            gluon_parser::ast::Type::Matrix(_) => Type::Matrix(MatrixTypeInfo {
                rows: 0,
                cols: 0,
                scalar_type: Box::new(Type::Inferred),
            }),
            gluon_parser::ast::Type::Refinement(inner, _) => self.ast_type_to_type(inner),
            gluon_parser::ast::Type::Param(_) => Type::Inferred,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum TypeError {
    Mismatch { expected: Type, found: Type, span: Span },
    DimensionMismatch { expected: Dimension, found: Dimension, span: Span },
    Undefined { name: String, span: Span },
    NotARegion { name: String, span: Span },
    ReadOnlyViolation { name: String, span: Span },
}

impl fmt::Display for TypeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            TypeError::Mismatch { expected, found, span } => {
                write!(f, "type mismatch at {}: expected {:?}, found {:?}", span, expected, found)
            }
            TypeError::DimensionMismatch { expected, found, span } => {
                write!(f, "dimension mismatch at {}: expected {}, found {}", span, expected, found)
            }
            TypeError::Undefined { name, span } => {
                write!(f, "undefined name '{}' at {}", name, span)
            }
            TypeError::NotARegion { name, span } => {
                write!(f, "'{}' is not a region at {}", name, span)
            }
            TypeError::ReadOnlyViolation { name, span } => {
                write!(f, "cannot write to read-only region '{}' at {}", name, span)
            }
        }
    }
}