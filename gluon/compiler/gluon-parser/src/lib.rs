pub mod ast;
pub mod parser;

pub use parser::Parser;

#[derive(Debug, Clone)]
pub struct ParseError {
    pub message: String,
    pub span: gluon_lexer::Span,
}

impl std::fmt::Display for ParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "parse error at {}: {}", self.span, self.message)
    }
}

impl std::error::Error for ParseError {}

pub type ParseResult<T> = Result<T, ParseError>;