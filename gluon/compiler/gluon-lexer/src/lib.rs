use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Span {
    pub start: usize,
    pub end: usize,
    pub line: usize,
    pub col: usize,
}

impl Span {
    pub fn new(start: usize, end: usize, line: usize, col: usize) -> Self {
        Span { start, end, line, col }
    }

    pub fn zero() -> Self {
        Span { start: 0, end: 0, line: 1, col: 1 }
    }

    pub fn merge(&self, other: &Span) -> Span {
        Span {
            start: self.start.min(other.start),
            end: self.end.max(other.end),
            line: self.line,
            col: self.col,
        }
    }
}

impl fmt::Display for Span {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}:{}", self.line, self.col)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum TokenKind {
    IntLit(u64),
    FloatLit(f64),
    ColorLit(u32),
    StringLit(String),
    BoolLit(bool),
    IntWithUnit(u64, String),
    FloatWithUnit(f64, String),
    Ident(String),
    TypeIdent(String),

    Process, Region, Reads, Writes, Private,
    When, Every, On, Call, Changes,
    Ensures, Requires, Invariant, Temporal,
    Always, Eventually, Until, Next, Forall, Exists,
    If, Then, Else, For, Each, In, While,
    And, Or, Not, Is, As, Of, AtKw, To, WithKw,
    Return, Let, Assert, Assume, End, Kill, SelfKw,

    ShortTerm, LongTerm, ReadOnly, ReadWrite,
    U8x4, F32x4, U16x4, Raw, Spatial,

    Migrate, Persist, Project, Blend, Evolve,
    Convolve, Broadcast, Reshape, Compose, Draw,
    Fill, Clear, Swap, Spawn, Grant, Revoke,
    Into, Over, Onto, Through, From, By,

    Plus, Minus, Star, Slash, Percent, Caret,
    EqEq, Neq, Lt, Gt, Lte, Gte,
    ApproxEq, ColonEq, Eq, Colon, Cross, Arrow,
    Dot, Comma, Semicolon,
    LParen, RParen, LBracket, RBracket, LBrace, RBrace,
    At, Pipe, Ampersand, LShift, RShift, DoubleDot,

    Eof,
}

#[derive(Debug, Clone)]
pub struct Token {
    pub kind: TokenKind,
    pub span: Span,
}

impl Token {
    pub fn new(kind: TokenKind, span: Span) -> Self {
        Token { kind, span }
    }
}

impl fmt::Display for TokenKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            TokenKind::IntLit(v) => write!(f, "{}", v),
            TokenKind::FloatLit(v) => write!(f, "{}", v),
            TokenKind::ColorLit(v) => write!(f, "#{:06X}", v),
            TokenKind::StringLit(v) => write!(f, "\"{}\"", v),
            TokenKind::BoolLit(v) => write!(f, "{}", v),
            TokenKind::IntWithUnit(v, u) => write!(f, "{}{}", v, u),
            TokenKind::FloatWithUnit(v, u) => write!(f, "{}{}", v, u),
            TokenKind::Ident(v) => write!(f, "{}", v),
            TokenKind::TypeIdent(v) => write!(f, "{}", v),
            TokenKind::Process => write!(f, "process"),
            TokenKind::Region => write!(f, "region"),
            TokenKind::Reads => write!(f, "reads"),
            TokenKind::Writes => write!(f, "writes"),
            TokenKind::Private => write!(f, "private"),
            TokenKind::When => write!(f, "when"),
            TokenKind::Every => write!(f, "every"),
            TokenKind::On => write!(f, "on"),
            TokenKind::Call => write!(f, "call"),
            TokenKind::Changes => write!(f, "changes"),
            TokenKind::Ensures => write!(f, "ensures"),
            TokenKind::Requires => write!(f, "requires"),
            TokenKind::Invariant => write!(f, "invariant"),
            TokenKind::Temporal => write!(f, "temporal"),
            TokenKind::Always => write!(f, "always"),
            TokenKind::Eventually => write!(f, "eventually"),
            TokenKind::Until => write!(f, "until"),
            TokenKind::Next => write!(f, "next"),
            TokenKind::Forall => write!(f, "forall"),
            TokenKind::Exists => write!(f, "exists"),
            TokenKind::If => write!(f, "if"),
            TokenKind::Then => write!(f, "then"),
            TokenKind::Else => write!(f, "else"),
            TokenKind::For => write!(f, "for"),
            TokenKind::Each => write!(f, "each"),
            TokenKind::In => write!(f, "in"),
            TokenKind::While => write!(f, "while"),
            TokenKind::And => write!(f, "and"),
            TokenKind::Or => write!(f, "or"),
            TokenKind::Not => write!(f, "not"),
            TokenKind::Is => write!(f, "is"),
            TokenKind::As => write!(f, "as"),
            TokenKind::Of => write!(f, "of"),
            TokenKind::AtKw => write!(f, "at"),
            TokenKind::To => write!(f, "to"),
            TokenKind::WithKw => write!(f, "with"),
            TokenKind::Return => write!(f, "return"),
            TokenKind::Let => write!(f, "let"),
            TokenKind::Assert => write!(f, "assert"),
            TokenKind::Assume => write!(f, "assume"),
            TokenKind::End => write!(f, "end"),
            TokenKind::Kill => write!(f, "kill"),
            TokenKind::SelfKw => write!(f, "self"),
            TokenKind::ShortTerm => write!(f, "ShortTerm"),
            TokenKind::LongTerm => write!(f, "LongTerm"),
            TokenKind::ReadOnly => write!(f, "ReadOnly"),
            TokenKind::ReadWrite => write!(f, "ReadWrite"),
            TokenKind::U8x4 => write!(f, "U8x4"),
            TokenKind::F32x4 => write!(f, "F32x4"),
            TokenKind::U16x4 => write!(f, "U16x4"),
            TokenKind::Raw => write!(f, "Raw"),
            TokenKind::Spatial => write!(f, "Spatial"),
            TokenKind::Migrate => write!(f, "migrate"),
            TokenKind::Persist => write!(f, "persist"),
            TokenKind::Project => write!(f, "project"),
            TokenKind::Blend => write!(f, "blend"),
            TokenKind::Evolve => write!(f, "evolve"),
            TokenKind::Convolve => write!(f, "convolve"),
            TokenKind::Broadcast => write!(f, "broadcast"),
            TokenKind::Reshape => write!(f, "reshape"),
            TokenKind::Compose => write!(f, "compose"),
            TokenKind::Draw => write!(f, "draw"),
            TokenKind::Fill => write!(f, "fill"),
            TokenKind::Clear => write!(f, "clear"),
            TokenKind::Swap => write!(f, "swap"),
            TokenKind::Spawn => write!(f, "spawn"),
            TokenKind::Grant => write!(f, "grant"),
            TokenKind::Revoke => write!(f, "revoke"),
            TokenKind::Into => write!(f, "into"),
            TokenKind::Over => write!(f, "over"),
            TokenKind::Onto => write!(f, "onto"),
            TokenKind::Through => write!(f, "through"),
            TokenKind::From => write!(f, "from"),
            TokenKind::By => write!(f, "by"),
            TokenKind::Plus => write!(f, "+"),
            TokenKind::Minus => write!(f, "-"),
            TokenKind::Star => write!(f, "*"),
            TokenKind::Slash => write!(f, "/"),
            TokenKind::Percent => write!(f, "%"),
            TokenKind::Caret => write!(f, "^"),
            TokenKind::EqEq => write!(f, "=="),
            TokenKind::Neq => write!(f, "!="),
            TokenKind::Lt => write!(f, "<"),
            TokenKind::Gt => write!(f, ">"),
            TokenKind::Lte => write!(f, "<="),
            TokenKind::Gte => write!(f, ">="),
            TokenKind::ApproxEq => write!(f, "\u{2248}"),
            TokenKind::ColonEq => write!(f, ":="),
            TokenKind::Eq => write!(f, "="),
            TokenKind::Colon => write!(f, ":"),
            TokenKind::Cross => write!(f, "\u{00D7}"),
            TokenKind::Arrow => write!(f, "\u{2192}"),
            TokenKind::Dot => write!(f, "."),
            TokenKind::Comma => write!(f, ","),
            TokenKind::Semicolon => write!(f, ";"),
            TokenKind::LParen => write!(f, "("),
            TokenKind::RParen => write!(f, ")"),
            TokenKind::LBracket => write!(f, "["),
            TokenKind::RBracket => write!(f, "]"),
            TokenKind::LBrace => write!(f, "{{"),
            TokenKind::RBrace => write!(f, "}}"),
            TokenKind::At => write!(f, "@"),
            TokenKind::Pipe => write!(f, "|"),
            TokenKind::Ampersand => write!(f, "&"),
            TokenKind::LShift => write!(f, "<<"),
            TokenKind::RShift => write!(f, ">>"),
            TokenKind::DoubleDot => write!(f, ".."),
            TokenKind::Eof => write!(f, "<eof>"),
        }
    }
}

#[derive(Debug, Clone)]
pub struct LexerError {
    pub message: String,
    pub span: Span,
}

impl fmt::Display for LexerError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "lexer error at {}: {}", self.span, self.message)
    }
}

impl std::error::Error for LexerError {}

pub struct Lexer {
    source: Vec<char>,
    pos: usize,
    line: usize,
    col: usize,
    tokens: Vec<Result<Token, LexerError>>,
}

impl Lexer {
    pub fn new(source: &str) -> Self {
        Lexer {
            source: source.chars().collect(),
            pos: 0,
            line: 1,
            col: 1,
            tokens: Vec::new(),
        }
    }

    pub fn tokenize(mut self) -> Result<Vec<Token>, Vec<LexerError>> {
        let mut errors = Vec::new();
        loop {
            match self.next_token() {
                Ok(tok) => {
                    let is_eof = matches!(tok.kind, TokenKind::Eof);
                    self.tokens.push(Ok(tok));
                    if is_eof { break; }
                }
                Err(e) => {
                    errors.push(e.clone());
                    self.tokens.push(Err(e));
                }
            }
        }
        if errors.is_empty() {
            Ok(self.tokens.into_iter().map(|r| r.unwrap()).collect())
        } else {
            Err(errors)
        }
    }

    fn peek(&self) -> Option<char> { self.source.get(self.pos).copied() }
    fn peek_next(&self) -> Option<char> { self.source.get(self.pos + 1).copied() }

    fn advance(&mut self) -> Option<char> {
        let ch = self.source.get(self.pos).copied();
        if let Some(c) = ch {
            self.pos += 1;
            if c == '\n' { self.line += 1; self.col = 1; } else { self.col += 1; }
        }
        ch
    }

    fn skip_whitespace(&mut self) {
        while let Some(c) = self.peek() {
            if c == ' ' || c == '\t' || c == '\n' || c == '\r' { self.advance(); } else { break; }
        }
    }

    fn skip_comment(&mut self) -> bool {
        if self.peek() == Some('-') && self.peek_next() == Some('-') {
            self.advance(); self.advance();
            if self.peek() == Some('-') { self.advance(); } // doc comment
            while let Some(c) = self.peek() {
                if c == '\n' { self.advance(); break; }
                self.advance();
            }
            true
        } else { false }
    }

    fn make_span(&self, start_pos: usize, start_line: usize, start_col: usize) -> Span {
        Span::new(start_pos, self.pos, start_line, start_col)
    }

    fn next_token(&mut self) -> Result<Token, LexerError> {
        loop {
            self.skip_whitespace();
            if self.peek().is_none() {
                return Ok(Token::new(TokenKind::Eof, Span::new(self.pos, self.pos, self.line, self.col)));
            }
            if self.skip_comment() { continue; }
            break;
        }

        let start_pos = self.pos;
        let start_line = self.line;
        let start_col = self.col;
        let ch = self.peek().unwrap();

        if ch == '#' {
            self.advance();
            let mut hex = String::new();
            while let Some(c) = self.peek() { if c.is_ascii_hexdigit() { hex.push(c); self.advance(); } else { break; } }
            let span = self.make_span(start_pos, start_line, start_col);
            if hex.len() == 6 || hex.len() == 8 {
                let val = u32::from_str_radix(&hex, 16).map_err(|_| LexerError { message: format!("invalid color literal #{}", hex), span: span.clone() })?;
                Ok(Token::new(TokenKind::ColorLit(val), span))
            } else { Err(LexerError { message: format!("color literal must be #RRGGBB or #RRGGBBAA, got #{}", hex), span }) }
        } else if ch == '"' {
            self.advance();
            let mut s = String::new();
            while let Some(c) = self.peek() {
                if c == '"' { self.advance(); break; }
                if c == '\\' { self.advance(); let e = self.advance().unwrap(); match e { 'n' => s.push('\n'), 't' => s.push('\t'), 'r' => s.push('\r'), '\\' => s.push('\\'), '"' => s.push('"'), _ => s.push(e) } }
                else { s.push(c); self.advance(); }
            }
            Ok(Token::new(TokenKind::StringLit(s), self.make_span(start_pos, start_line, start_col)))
        } else if ch.is_ascii_digit() {
            let mut num_str = String::new();
            let mut is_float = false;
            if ch == '0' && self.peek_next() == Some('x') {
                self.advance(); self.advance();
                while let Some(c) = self.peek() { if c.is_ascii_hexdigit() { num_str.push(c); self.advance(); } else { break; } }
                let val = u64::from_str_radix(&num_str, 16).unwrap();
                let span = self.make_span(start_pos, start_line, start_col);
                return if let Some(unit) = self.maybe_unit() { Ok(Token::new(TokenKind::IntWithUnit(val, unit), span)) }
                    else { Ok(Token::new(TokenKind::IntLit(val), span)) };
            }
            while let Some(c) = self.peek() {
                if c.is_ascii_digit() { num_str.push(c); self.advance(); }
                else if c == '.' && self.peek_next() != Some('.') { is_float = true; num_str.push(c); self.advance(); }
                else { break; }
            }
            if let Some('e') | Some('E') = self.peek() {
                is_float = true; num_str.push(self.advance().unwrap());
                if let Some('+') | Some('-') = self.peek() { num_str.push(self.advance().unwrap()); }
                while let Some(c) = self.peek() { if c.is_ascii_digit() { num_str.push(c); self.advance(); } else { break; } }
            }
            let span = self.make_span(start_pos, start_line, start_col);
            let unit = self.maybe_unit();
            if is_float {
                let val = num_str.parse::<f64>().map_err(|_| LexerError { message: format!("invalid float literal: {}", num_str), span: span.clone() })?;
                if let Some(u) = unit { Ok(Token::new(TokenKind::FloatWithUnit(val, u), span)) } else { Ok(Token::new(TokenKind::FloatLit(val), span)) }
            } else {
                let val = num_str.parse::<u64>().map_err(|_| LexerError { message: format!("invalid integer literal: {}", num_str), span: span.clone() })?;
                if let Some(u) = unit { Ok(Token::new(TokenKind::IntWithUnit(val, u), span)) } else { Ok(Token::new(TokenKind::IntLit(val), span)) }
            }
        } else if ch.is_alphabetic() || ch == '_' {
            let mut ident = String::new();
            while let Some(c) = self.peek() { if c.is_alphanumeric() || c == '_' { ident.push(c); self.advance(); } else { break; } }
            let span = self.make_span(start_pos, start_line, start_col);
            Ok(Token::new(lookup_keyword(&ident, &span), span))
        } else if ch == ':' && self.peek_next() == Some('=') { self.advance(); self.advance(); Ok(Token::new(TokenKind::ColonEq, self.make_span(start_pos, start_line, start_col))) }
        else if ch == '=' && self.peek_next() == Some('=') { self.advance(); self.advance(); Ok(Token::new(TokenKind::EqEq, self.make_span(start_pos, start_line, start_col))) }
        else if ch == '!' && self.peek_next() == Some('=') { self.advance(); self.advance(); Ok(Token::new(TokenKind::Neq, self.make_span(start_pos, start_line, start_col))) }
        else if ch == '<' && self.peek_next() == Some('<') { self.advance(); self.advance(); Ok(Token::new(TokenKind::LShift, self.make_span(start_pos, start_line, start_col))) }
        else if ch == '>' && self.peek_next() == Some('>') { self.advance(); self.advance(); Ok(Token::new(TokenKind::RShift, self.make_span(start_pos, start_line, start_col))) }
        else if ch == '<' && self.peek_next() == Some('=') { self.advance(); self.advance(); Ok(Token::new(TokenKind::Lte, self.make_span(start_pos, start_line, start_col))) }
        else if ch == '>' && self.peek_next() == Some('=') { self.advance(); self.advance(); Ok(Token::new(TokenKind::Gte, self.make_span(start_pos, start_line, start_col))) }
        else if ch == '.' && self.peek_next() == Some('.') { self.advance(); self.advance(); Ok(Token::new(TokenKind::DoubleDot, self.make_span(start_pos, start_line, start_col))) }
        else if ch == '\u{00D7}' { self.advance(); Ok(Token::new(TokenKind::Cross, self.make_span(start_pos, start_line, start_col))) }
        else if ch == '\u{2192}' { self.advance(); Ok(Token::new(TokenKind::Arrow, self.make_span(start_pos, start_line, start_col))) }
        else if ch == '\u{2248}' { self.advance(); Ok(Token::new(TokenKind::ApproxEq, self.make_span(start_pos, start_line, start_col))) }
        else {
            let kind = match self.advance().unwrap() {
                '+' => TokenKind::Plus, '-' => TokenKind::Minus, '*' => TokenKind::Star, '/' => TokenKind::Slash,
                '%' => TokenKind::Percent, '^' => TokenKind::Caret, '<' => TokenKind::Lt, '>' => TokenKind::Gt,
                '=' => TokenKind::Eq, ':' => TokenKind::Colon, '.' => TokenKind::Dot, ',' => TokenKind::Comma,
                ';' => TokenKind::Semicolon, '(' => TokenKind::LParen, ')' => TokenKind::RParen,
                '[' => TokenKind::LBracket, ']' => TokenKind::RBracket, '{' => TokenKind::LBrace, '}' => TokenKind::RBrace,
                '@' => TokenKind::At, '|' => TokenKind::Pipe, '&' => TokenKind::Ampersand,
                c => return Err(LexerError { message: format!("unexpected character: {:?}", c), span: Span::new(start_pos, self.pos, start_line, start_col) }),
            };
            Ok(Token::new(kind, self.make_span(start_pos, start_line, start_col)))
        }
    }

    fn maybe_unit(&mut self) -> Option<String> {
        let save_pos = self.pos;
        let save_line = self.line;
        let save_col = self.col;
        if let Some(c) = self.peek() {
            if c.is_alphabetic() || c == '\u{00B0}' || c == '\u{03BC}' {
                let mut unit = String::new();
                while let Some(c) = self.peek() { if c.is_alphanumeric() || c == '_' || c == '\u{00B0}' || c == '\u{03BC}' { unit.push(c); self.advance(); } else { break; } }
                if is_keyword_only(&unit) { self.pos = save_pos; self.line = save_line; self.col = save_col; return None; }
                Some(unit)
            } else { None }
        } else { None }
    }
}

fn is_keyword_only(s: &str) -> bool {
    matches!(s,
        "process" | "region" | "reads" | "writes" | "private" | "when" | "every" | "on" | "call"
        | "changes" | "ensures" | "requires" | "invariant" | "temporal" | "always" | "eventually"
        | "until" | "next" | "forall" | "exists" | "if" | "then" | "else" | "for" | "each" | "in"
        | "while" | "and" | "or" | "not" | "is" | "as" | "of" | "at" | "to" | "with" | "return"
        | "let" | "assert" | "assume" | "end" | "kill" | "self" | "true" | "false"
        | "ShortTerm" | "LongTerm" | "ReadOnly" | "ReadWrite"
        | "U8x4" | "F32x4" | "U16x4" | "Raw" | "Spatial"
        | "migrate" | "persist" | "project" | "blend" | "evolve" | "convolve" | "broadcast"
        | "reshape" | "compose" | "draw" | "fill" | "clear" | "swap" | "spawn" | "grant" | "revoke"
        | "into" | "over" | "onto" | "through" | "from" | "by"
    )
}

fn lookup_keyword(ident: &str, _span: &Span) -> TokenKind {
    match ident {
        "process" => TokenKind::Process, "region" => TokenKind::Region,
        "reads" => TokenKind::Reads, "writes" => TokenKind::Writes, "private" => TokenKind::Private,
        "when" => TokenKind::When, "every" => TokenKind::Every, "on" => TokenKind::On,
        "call" => TokenKind::Call, "changes" => TokenKind::Changes,
        "ensures" => TokenKind::Ensures, "requires" => TokenKind::Requires,
        "invariant" => TokenKind::Invariant, "temporal" => TokenKind::Temporal,
        "always" => TokenKind::Always, "eventually" => TokenKind::Eventually,
        "until" => TokenKind::Until, "next" => TokenKind::Next,
        "forall" => TokenKind::Forall, "exists" => TokenKind::Exists,
        "if" => TokenKind::If, "then" => TokenKind::Then, "else" => TokenKind::Else,
        "for" => TokenKind::For, "each" => TokenKind::Each, "in" => TokenKind::In,
        "while" => TokenKind::While, "and" => TokenKind::And, "or" => TokenKind::Or,
        "not" => TokenKind::Not, "is" => TokenKind::Is, "as" => TokenKind::As,
        "of" => TokenKind::Of, "at" => TokenKind::AtKw, "to" => TokenKind::To,
        "with" => TokenKind::WithKw,
        "return" => TokenKind::Return, "let" => TokenKind::Let,
        "assert" => TokenKind::Assert, "assume" => TokenKind::Assume,
        "end" => TokenKind::End, "kill" => TokenKind::Kill, "self" => TokenKind::SelfKw,
        "true" => TokenKind::BoolLit(true), "false" => TokenKind::BoolLit(false),
        "ShortTerm" => TokenKind::ShortTerm, "LongTerm" => TokenKind::LongTerm,
        "ReadOnly" => TokenKind::ReadOnly, "ReadWrite" => TokenKind::ReadWrite,
        "U8x4" => TokenKind::U8x4, "F32x4" => TokenKind::F32x4,
        "U16x4" => TokenKind::U16x4, "Raw" => TokenKind::Raw, "Spatial" => TokenKind::Spatial,
        "migrate" => TokenKind::Migrate, "persist" => TokenKind::Persist,
        "project" => TokenKind::Project, "blend" => TokenKind::Blend,
        "evolve" => TokenKind::Evolve, "convolve" => TokenKind::Convolve,
        "broadcast" => TokenKind::Broadcast, "reshape" => TokenKind::Reshape,
        "compose" => TokenKind::Compose, "draw" => TokenKind::Draw,
        "fill" => TokenKind::Fill, "clear" => TokenKind::Clear,
        "swap" => TokenKind::Swap, "spawn" => TokenKind::Spawn,
        "grant" => TokenKind::Grant, "revoke" => TokenKind::Revoke,
        "into" => TokenKind::Into, "over" => TokenKind::Over,
        "onto" => TokenKind::Onto, "through" => TokenKind::Through,
        "from" => TokenKind::From, "by" => TokenKind::By,
        _ => if ident.starts_with(char::is_uppercase) { TokenKind::TypeIdent(ident.to_string()) }
             else { TokenKind::Ident(ident.to_string()) },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lex(input: &str) -> Vec<Token> {
        Lexer::new(input).tokenize().expect("lexer should succeed")
    }

    #[test]
    fn test_basic_tokens() {
        let tokens = lex("process region reads writes private");
        assert!(matches!(tokens[0].kind, TokenKind::Process));
        assert!(matches!(tokens[1].kind, TokenKind::Region));
        assert!(matches!(tokens[2].kind, TokenKind::Reads));
        assert!(matches!(tokens[3].kind, TokenKind::Writes));
    }

    #[test]
    fn test_unit_literals() {
        let tokens = lex("1920px 16ms");
        assert!(matches!(&tokens[0].kind, TokenKind::IntWithUnit(v, u) if *v == 1920 && u == "px"));
        assert!(matches!(&tokens[1].kind, TokenKind::IntWithUnit(v, u) if *v == 16 && u == "ms"));
    }

    #[test]
    fn test_color_literal() {
        let tokens = lex("#1E1E2E");
        assert!(matches!(tokens[0].kind, TokenKind::ColorLit(0x1E1E2E)));
    }

    #[test]
    fn test_operators() {
        let tokens = lex(":= == != <= >= .. @");
        assert!(matches!(tokens[0].kind, TokenKind::ColonEq));
        assert!(matches!(tokens[1].kind, TokenKind::EqEq));
        assert!(matches!(tokens[2].kind, TokenKind::Neq));
        assert!(matches!(tokens[3].kind, TokenKind::Lte));
        assert!(matches!(tokens[4].kind, TokenKind::Gte));
        assert!(matches!(tokens[5].kind, TokenKind::DoubleDot));
        assert!(matches!(tokens[6].kind, TokenKind::At));
    }

    #[test]
    fn test_comments() {
        let tokens = lex("process -- comment\nregion");
        assert!(matches!(tokens[0].kind, TokenKind::Process));
        assert!(matches!(tokens[1].kind, TokenKind::Region));
    }

    #[test]
    fn test_string_literal() {
        let tokens = lex("\"hello world\"");
        assert!(matches!(&tokens[0].kind, TokenKind::StringLit(s) if s == "hello world"));
    }

    #[test]
    fn test_full_process() {
        let source = "process counter:\n  reads shared @ ReadOnly;\n  writes tick;\n  when tick changes:\n    count := count + 1;\n  end\n";
        let tokens = Lexer::new(source).tokenize().expect("should lex");
        assert!(tokens.len() > 5);
        assert!(matches!(tokens[0].kind, TokenKind::Process));
    }

    #[test]
    fn test_no_unit_on_keyword() {
        let tokens = lex("5process");
        assert!(matches!(tokens[0].kind, TokenKind::IntLit(5)));
        assert!(matches!(tokens[1].kind, TokenKind::Process));
    }
}