use gluon_lexer::{Lexer, Span, Token, TokenKind};

use crate::ast::*;
use crate::{ParseError, ParseResult};

pub struct Parser {
    tokens: Vec<Token>,
    pos: usize,
}

impl Parser {
    pub fn new(tokens: Vec<Token>) -> Self {
        Parser { tokens, pos: 0 }
    }

    pub fn from_source(source: &str) -> Result<Self, Vec<gluon_lexer::LexerError>> {
        let tokens = Lexer::new(source).tokenize()?;
        Ok(Parser::new(tokens))
    }

    pub fn parse_module(mut self) -> ParseResult<Module> {
        let mut items = Vec::new();
        let start = self.current_span();
        while !self.at_eof() {
            if let Some(item) = self.parse_item()? {
                items.push(item);
            }
        }
        Ok(Module {
            items,
            span: start.merge(&self.current_span()),
        })
    }

    fn peek(&self) -> &TokenKind {
        self.tokens.get(self.pos).map(|t| &t.kind).unwrap_or(&TokenKind::Eof)
    }

    fn peek_span(&self) -> Span {
        self.tokens.get(self.pos).map(|t| t.span).unwrap_or_else(|| {
            self.tokens.last().map(|t| t.span).unwrap_or(Span::zero())
        })
    }

    fn advance(&mut self) -> Token {
        let tok = self.tokens.get(self.pos).cloned().unwrap_or(Token::new(TokenKind::Eof, Span::zero()));
        self.pos += 1;
        tok
    }

    fn expect(&mut self, kind: TokenKind) -> ParseResult<Token> {
        let tok = self.advance();
        if std::mem::discriminant(&tok.kind) == std::mem::discriminant(&kind) {
            Ok(tok)
        } else {
            Err(ParseError {
                message: format!("expected {:?}, got {}", kind, tok.kind),
                span: tok.span,
            })
        }
    }

    fn expect_ident(&mut self) -> ParseResult<Ident> {
        let tok = self.advance();
        match &tok.kind {
            TokenKind::Ident(s) => Ok(Ident(s.clone(), tok.span)),
            _ => Err(ParseError {
                message: format!("expected identifier, got {}", tok.kind),
                span: tok.span,
            }),
        }
    }

    fn match_kind(&mut self, kind: &TokenKind) -> bool {
        if std::mem::discriminant(self.peek()) == std::mem::discriminant(kind) {
            self.advance();
            true
        } else {
            false
        }
    }

    fn at_eof(&self) -> bool {
        matches!(self.peek(), TokenKind::Eof) || self.pos >= self.tokens.len()
    }

    fn peek_is_ident(&self) -> bool {
        matches!(self.peek(), TokenKind::Ident(_))
    }

    fn current_span(&self) -> Span {
        self.peek_span()
    }

    fn skip_semicolons(&mut self) {
        while matches!(self.peek(), TokenKind::Semicolon) {
            self.advance();
        }
    }

    fn parse_item(&mut self) -> ParseResult<Option<Item>> {
        self.skip_semicolons();
        if self.at_eof() {
            return Ok(None);
        }
        match self.peek() {
            TokenKind::Region => Ok(Some(Item::RegionDecl(self.parse_region_decl()?))),
            TokenKind::Process => Ok(Some(Item::ProcessDecl(self.parse_process_decl()?))),
            TokenKind::Temporal => Ok(Some(self.parse_temporal_spec()?)),
            _ => {
                let span = self.current_span();
                Err(ParseError {
                    message: format!("expected region, process, or temporal, got {}", self.peek()),
                    span,
                })
            }
        }
    }

    fn parse_region_decl(&mut self) -> ParseResult<RegionDecl> {
        let start = self.current_span();
        self.expect(TokenKind::Region)?;
        let name = self.expect_ident()?;
        self.expect(TokenKind::Colon)?;
        let region_type = self.parse_region_type()?;
        let mut invariants = Vec::new();
        while matches!(self.peek(), TokenKind::Invariant) {
            self.advance();
            self.expect(TokenKind::Colon)?;
            invariants.push(self.parse_predicate()?);
            self.skip_semicolons();
        }
        self.skip_semicolons();
        Ok(RegionDecl {
            name,
            region_type,
            invariants,
            span: start.merge(&self.current_span()),
        })
    }

    fn parse_region_type(&mut self) -> ParseResult<RegionType> {
        let kind = match self.peek() {
            TokenKind::Ident(s) if s == "graphics" => { self.advance(); Some(RegionKind::Graphics) }
            TokenKind::Ident(s) if s == "input" => { self.advance(); Some(RegionKind::Input) }
            TokenKind::Ident(s) if s == "quantum" => { self.advance(); Some(RegionKind::Quantum) }
            TokenKind::Ident(s) if s == "neural" => { self.advance(); Some(RegionKind::Neural) }
            TokenKind::Ident(s) if s == "dna" => { self.advance(); Some(RegionKind::Dna) }
            _ => None,
        };

        self.expect(TokenKind::Region)?;
        self.expect(TokenKind::LBracket)?;
        let dimensions = self.parse_dimension_specs()?;
        self.expect(TokenKind::RBracket)?;
        self.expect(TokenKind::Of)?;

        let format = self.parse_element_format()?;

        let tier = if self.match_kind(&TokenKind::At) {
            Some(self.parse_tier()?)
        } else {
            None
        };

        let access = if self.match_kind(&TokenKind::At) {
            Some(self.parse_access()?)
        } else {
            None
        };

        Ok(RegionType { kind, dimensions, format, tier, access })
    }

    fn parse_dimension_specs(&mut self) -> ParseResult<Vec<DimensionSpec>> {
        let mut specs = Vec::new();
        specs.push(self.parse_dimension_spec()?);
        while self.match_kind(&TokenKind::Comma) {
            specs.push(self.parse_dimension_spec()?);
        }
        Ok(specs)
    }

    fn parse_dimension_spec(&mut self) -> ParseResult<DimensionSpec> {
        let name = self.expect_ident()?;
        self.expect(TokenKind::Colon)?;
        let ((size, _span), unit_from_literal) = self.parse_dim_expr_with_unit()?;
        let unit = unit_from_literal.unwrap_or_else(|| self.parse_or_default_unit());
        Ok(DimensionSpec { name, size, unit })
    }

    fn parse_dim_expr_with_unit(&mut self) -> ParseResult<((DimExpr, Span), Option<String>)> {
        let tok = self.peek().clone();
        match tok {
            TokenKind::IntLit(v) => {
                let span = self.peek_span();
                let val = v;
                self.advance();
                Ok(((DimExpr::Literal(val, span), span), None))
            }
            TokenKind::IntWithUnit(v, ref u) => {
                let span = self.peek_span();
                let val = v;
                let unit = u.clone();
                self.advance();
                Ok(((DimExpr::Literal(val, span), span), Some(unit)))
            }
            TokenKind::Ident(_) => {
                let ident = self.expect_ident()?;
                Ok(((DimExpr::Param(ident.clone()), ident.1), None))
            }
            _ => Err(ParseError {
                message: format!("expected dimension size, got {}", self.peek()),
                span: self.current_span(),
            }),
        }
    }

    fn parse_or_default_unit(&mut self) -> String {
        let tok = self.peek().clone();
        match tok {
            TokenKind::IntWithUnit(_, ref u) | TokenKind::FloatWithUnit(_, ref u) => {
                let unit = u.clone();
                self.advance();
                unit
            }
            TokenKind::Ident(ref s) if !is_keyword(s) => {
                let unit = s.clone();
                self.advance();
                unit
            }
            _ => "dimensionless".to_string(),
        }
    }

    fn parse_element_format(&mut self) -> ParseResult<ElementFormat> {
        match self.peek() {
            TokenKind::Raw => { self.advance(); Ok(ElementFormat::Raw) }
            TokenKind::U8x4 => { self.advance(); Ok(ElementFormat::U8x4) }
            TokenKind::F32x4 => { self.advance(); Ok(ElementFormat::F32x4) }
            TokenKind::U16x4 => { self.advance(); Ok(ElementFormat::U16x4) }
            _ => Err(ParseError {
                message: format!("expected element format (Raw, U8x4, F32x4, U16x4), got {}", self.peek()),
                span: self.current_span(),
            }),
        }
    }

    fn parse_tier(&mut self) -> ParseResult<Tier> {
        match self.peek() {
            TokenKind::ShortTerm => { self.advance(); Ok(Tier::ShortTerm) }
            TokenKind::LongTerm => { self.advance(); Ok(Tier::LongTerm) }
            _ => Err(ParseError {
                message: format!("expected ShortTerm or LongTerm, got {}", self.peek()),
                span: self.current_span(),
            }),
        }
    }

    fn parse_access(&mut self) -> ParseResult<Access> {
        match self.peek() {
            TokenKind::ReadOnly => { self.advance(); Ok(Access::ReadOnly) }
            TokenKind::ReadWrite => { self.advance(); Ok(Access::ReadWrite) }
            _ => Err(ParseError {
                message: format!("expected ReadOnly or ReadWrite, got {}", self.peek()),
                span: self.current_span(),
            }),
        }
    }

    fn parse_process_decl(&mut self) -> ParseResult<ProcessDecl> {
        let start = self.current_span();
        self.expect(TokenKind::Process)?;
        let name = self.expect_ident()?;
        self.expect(TokenKind::Colon)?;

        let mut reads = Vec::new();
        let mut writes = Vec::new();
        let mut privates = Vec::new();
        let mut constrains = Vec::new();
        let mut requires_list = Vec::new();
        let mut ensures_list = Vec::new();
        let mut temporal_invariants = Vec::new();
        let mut react_blocks = Vec::new();

        self.skip_semicolons();

        // Parse reads
        if self.match_kind(&TokenKind::Reads) {
            reads = self.parse_access_list()?;
            self.skip_semicolons();
        }

        // Parse writes
        if self.match_kind(&TokenKind::Writes) {
            writes = self.parse_access_list()?;
            self.skip_semicolons();
        }

        // Parse private declarations
        if self.match_kind(&TokenKind::Private) {
            privates = self.parse_private_decls()?;
            self.skip_semicolons();
        }

        // Parse constrains
        while matches!(self.peek(), TokenKind::Ident(s) if s == "constrains") {
            self.advance();
            let region_name = self.expect_ident()?;
            self.expect(TokenKind::Colon)?;
            constrains.push((region_name, self.parse_predicate()?));
            self.skip_semicolons();
        }

        // Parse requires
        if self.match_kind(&TokenKind::Requires) {
            self.expect(TokenKind::Colon)?;
            requires_list = self.parse_predicate_list()?;
            self.skip_semicolons();
        }

        // Parse react blocks
        loop {
            match self.peek() {
                TokenKind::When => react_blocks.push(ReactBlock::When(self.parse_when_block()?)),
                TokenKind::Every => react_blocks.push(ReactBlock::Every(self.parse_every_block()?)),
                TokenKind::On => react_blocks.push(ReactBlock::Call(self.parse_call_block()?)),
                TokenKind::Ensures => break,
                TokenKind::End => break,
                TokenKind::Temporal => break,
                _ => break,
            }
            self.skip_semicolons();
        }

        // Parse ensures
        if self.match_kind(&TokenKind::Ensures) {
            self.expect(TokenKind::Colon)?;
            ensures_list = self.parse_predicate_list()?;
            self.skip_semicolons();
        }

        // Parse temporal invariants
        if matches!(self.peek(), TokenKind::Temporal) {
            temporal_invariants = self.parse_temporal_spec_inner()?;
            self.skip_semicolons();
        }

        self.expect(TokenKind::End)?;
        self.skip_semicolons();

        Ok(ProcessDecl {
            name, reads, writes, privates, constrains,
            requires: requires_list, ensures: ensures_list,
            temporal_invariants, react_blocks,
            span: start.merge(&self.current_span()),
        })
    }

    fn parse_access_list(&mut self) -> ParseResult<Vec<(Ident, Option<Access>)>> {
        let mut items = Vec::new();
        let name = self.expect_ident()?;
        let access = if self.match_kind(&TokenKind::At) {
            Some(self.parse_access()?)
        } else {
            None
        };
        items.push((name, access));
        while self.match_kind(&TokenKind::Comma) {
            let name = self.expect_ident()?;
            let access = if self.match_kind(&TokenKind::At) {
                Some(self.parse_access()?)
            } else {
                None
            };
            items.push((name, access));
        }
        self.expect(TokenKind::Semicolon)?;
        Ok(items)
    }

    fn parse_private_decls(&mut self) -> ParseResult<Vec<PrivateDecl>> {
        let mut decls = Vec::new();
        let (name, type_ann, init) = self.parse_private_item()?;
        decls.push(PrivateDecl { name, type_ann, init, span: Span::zero() });
        while self.match_kind(&TokenKind::Comma) {
            let (name, type_ann, init) = self.parse_private_item()?;
            decls.push(PrivateDecl { name, type_ann, init, span: Span::zero() });
        }
        self.expect(TokenKind::Semicolon)?;
        Ok(decls)
    }

    fn parse_private_item(&mut self) -> ParseResult<(Ident, Option<Type>, Option<Expr>)> {
        let name = self.expect_ident()?;
        let type_ann = if self.match_kind(&TokenKind::Colon) {
            Some(self.parse_type()?)
        } else {
            None
        };
        let init = if self.match_kind(&TokenKind::Eq) {
            Some(self.parse_expr()?)
        } else {
            None
        };
        Ok((name, type_ann, init))
    }

    fn parse_when_block(&mut self) -> ParseResult<WhenBlock> {
        let start = self.current_span();
        self.expect(TokenKind::When)?;
        let mut triggers = vec![self.expect_ident()?];
        while self.match_kind(&TokenKind::Or) {
            triggers.push(self.expect_ident()?);
        }
        self.expect(TokenKind::Changes)?;
        self.expect(TokenKind::Colon)?;
        let body = self.parse_statements_until(&[TokenKind::When, TokenKind::Every, TokenKind::On, TokenKind::Ensures, TokenKind::End, TokenKind::Temporal])?;
        Ok(WhenBlock { triggers, body, span: start.merge(&self.current_span()) })
    }

    fn parse_every_block(&mut self) -> ParseResult<EveryBlock> {
        let start = self.current_span();
        self.expect(TokenKind::Every)?;
        let (duration, unit) = match self.advance().kind {
            TokenKind::FloatLit(v) | TokenKind::FloatWithUnit(v, _) => {
                let unit = match &self.tokens.get(self.pos - 1).unwrap().kind {
                    TokenKind::FloatWithUnit(_, ref u) => u.clone(),
                    _ => self.parse_or_default_unit(),
                };
                (v, unit)
            }
            TokenKind::IntLit(v) | TokenKind::IntWithUnit(v, _) => {
                let unit = match &self.tokens.get(self.pos - 1).unwrap().kind {
                    TokenKind::IntWithUnit(_, ref u) => u.clone(),
                    _ => self.parse_or_default_unit(),
                };
                (v as f64, unit)
            }
            _ => return Err(ParseError {
                message: "expected duration literal".to_string(),
                span: self.current_span(),
            }),
        };
        self.expect(TokenKind::Colon)?;
        let body = self.parse_statements_until(&[TokenKind::When, TokenKind::Every, TokenKind::On, TokenKind::Ensures, TokenKind::End, TokenKind::Temporal])?;
        Ok(EveryBlock { duration, unit, body, span: start.merge(&self.current_span()) })
    }

    fn parse_call_block(&mut self) -> ParseResult<CallBlock> {
        let start = self.current_span();
        self.expect(TokenKind::On)?;
        self.expect(TokenKind::Call)?;
        self.expect(TokenKind::LParen)?;
        let name = self.expect_ident()?;
        self.expect(TokenKind::Colon)?;
        let param_type = self.parse_type()?;
        self.expect(TokenKind::RParen)?;
        self.expect(TokenKind::Colon)?;
        let body = self.parse_statements_until(&[TokenKind::When, TokenKind::Every, TokenKind::On, TokenKind::Ensures, TokenKind::End])?;
        Ok(CallBlock { name: name.clone(), params: vec![(name, param_type)], return_type: None, body, span: start.merge(&self.current_span()) })
    }

    fn parse_statements_until(&mut self, terminators: &[TokenKind]) -> ParseResult<Vec<Statement>> {
        let mut stmts = Vec::new();
        loop {
            self.skip_semicolons();
            for t in terminators {
                if std::mem::discriminant(self.peek()) == std::mem::discriminant(t) {
                    return Ok(stmts);
                }
            }
            if self.at_eof() {
                return Ok(stmts);
            }
            if let Some(stmt) = self.parse_statement()? {
                stmts.push(stmt);
            } else {
                break;
            }
        }
        Ok(stmts)
    }

    fn parse_statement(&mut self) -> ParseResult<Option<Statement>> {
        self.skip_semicolons();
        if self.at_eof() {
            return Ok(None);
        }
        match self.peek() {
            TokenKind::Let => Ok(Some(self.parse_let_stmt()?)),
            TokenKind::Kill => Ok(Some(self.parse_kill_stmt()?)),
            TokenKind::If => Ok(Some(self.parse_if_stmt()?)),
            TokenKind::For => Ok(Some(self.parse_for_stmt()?)),
            TokenKind::Assert => Ok(Some(self.parse_assert_stmt()?)),
            TokenKind::Assume => Ok(Some(self.parse_assume_stmt()?)),
            TokenKind::Return => Ok(Some(self.parse_return_stmt()?)),
            TokenKind::Spawn => Ok(Some(self.parse_spawn_stmt()?)),
            TokenKind::Grant => Ok(Some(self.parse_grant_stmt()?)),
            TokenKind::Revoke => Ok(Some(self.parse_revoke_stmt()?)),
            TokenKind::Migrate => Ok(Some(self.parse_migrate_stmt()?)),
            TokenKind::Project | TokenKind::Blend | TokenKind::Evolve |
            TokenKind::Convolve | TokenKind::Clear | TokenKind::Swap |
            TokenKind::Persist | TokenKind::Fill | TokenKind::Draw |
            TokenKind::Compose | TokenKind::Reshape => Ok(Some(self.parse_builtin_stmt()?)),
            TokenKind::Ident(_) => Ok(Some(self.parse_ident_stmt()?)),
            _ => Ok(None),
        }
    }

    fn parse_let_stmt(&mut self) -> ParseResult<Statement> {
        let start = self.current_span();
        self.expect(TokenKind::Let)?;
        let name = self.expect_ident()?;
        let type_ann = if self.match_kind(&TokenKind::Colon) {
            Some(self.parse_type()?)
        } else {
            None
        };
        self.expect(TokenKind::Eq)?;
        let init = self.parse_expr()?;
        self.skip_semicolons();
        Ok(Statement::Let(LetStmt { name, type_ann, init, span: start.merge(&self.current_span()) }))
    }

    fn parse_kill_stmt(&mut self) -> ParseResult<Statement> {
        let start = self.current_span();
        self.expect(TokenKind::Kill)?;
        let target = if self.match_kind(&TokenKind::SelfKw) {
            None
        } else {
            Some(self.expect_ident()?)
        };
        self.skip_semicolons();
        Ok(Statement::Kill(target, start.merge(&self.current_span())))
    }

    fn parse_assert_stmt(&mut self) -> ParseResult<Statement> {
        let start = self.current_span();
        self.expect(TokenKind::Assert)?;
        let pred = self.parse_predicate()?;
        self.skip_semicolons();
        Ok(Statement::Assert(pred, start))
    }

    fn parse_assume_stmt(&mut self) -> ParseResult<Statement> {
        let start = self.current_span();
        self.expect(TokenKind::Assume)?;
        let pred = self.parse_predicate()?;
        self.skip_semicolons();
        Ok(Statement::Assume(pred, start))
    }

    fn parse_return_stmt(&mut self) -> ParseResult<Statement> {
        let start = self.current_span();
        self.expect(TokenKind::Return)?;
        let expr = if matches!(self.peek(), TokenKind::Semicolon | TokenKind::End) {
            None
        } else {
            Some(self.parse_expr()?)
        };
        self.skip_semicolons();
        Ok(Statement::Return(expr, start))
    }

    fn parse_if_stmt(&mut self) -> ParseResult<Statement> {
        let start = self.current_span();
        self.expect(TokenKind::If)?;
        let condition = self.parse_expr()?;
        self.expect(TokenKind::Colon)?;
        let then_body = self.parse_statements_until(&[TokenKind::Else, TokenKind::End])?;
        let mut else_ifs = Vec::new();
        let mut else_body = None;
        while matches!(self.peek(), TokenKind::Else) {
            self.advance();
            if self.match_kind(&TokenKind::If) {
                let cond = self.parse_expr()?;
                self.expect(TokenKind::Colon)?;
                let body = self.parse_statements_until(&[TokenKind::Else, TokenKind::End])?;
                else_ifs.push((cond, body));
            } else {
                self.expect(TokenKind::Colon)?;
                else_body = Some(self.parse_statements_until(&[TokenKind::End])?);
                break;
            }
        }
        self.expect(TokenKind::End)?;
        self.skip_semicolons();
        Ok(Statement::If(IfStmt { condition, then_body, else_ifs, else_body, span: start.merge(&self.current_span()) }))
    }

    fn parse_for_stmt(&mut self) -> ParseResult<Statement> {
        let start = self.current_span();
        self.expect(TokenKind::For)?;
        self.expect(TokenKind::Each)?;
        self.expect(TokenKind::LParen)?;
        let mut vars = vec![self.expect_ident()?];
        while self.match_kind(&TokenKind::Comma) {
            vars.push(self.expect_ident()?);
        }
        self.expect(TokenKind::RParen)?;
        self.expect(TokenKind::In)?;
        let iterable = self.parse_expr()?;
        self.expect(TokenKind::Colon)?;
        let body = self.parse_statements_until(&[TokenKind::End])?;
        self.expect(TokenKind::End)?;
        self.skip_semicolons();
        Ok(Statement::For(ForStmt { vars, iterable, body, span: start.merge(&self.current_span()) }))
    }

    fn parse_spawn_stmt(&mut self) -> ParseResult<Statement> {
        let start = self.current_span();
        self.expect(TokenKind::Spawn)?;
        let process_name = self.expect_ident()?;
        self.expect(TokenKind::WithKw)?;
        self.expect(TokenKind::LParen)?;

        let mut reads = Vec::new();
        let mut writes = Vec::new();

        if matches!(self.peek(), TokenKind::Reads) {
            self.advance();
            self.expect(TokenKind::Colon)?;
            self.expect(TokenKind::LBracket)?;
            loop {
                let name = self.expect_ident()?;
                let access = if self.match_kind(&TokenKind::At) { Some(self.parse_access()?) } else { None };
                reads.push((name, access));
                if !self.match_kind(&TokenKind::Comma) { break; }
            }
            self.expect(TokenKind::RBracket)?;
            self.match_kind(&TokenKind::Comma);
        }

        if matches!(self.peek(), TokenKind::Writes) {
            self.advance();
            self.expect(TokenKind::Colon)?;
            self.expect(TokenKind::LBracket)?;
            loop {
                let name = self.expect_ident()?;
                let access = if self.match_kind(&TokenKind::At) { Some(self.parse_access()?) } else { None };
                writes.push((name, access));
                if !self.match_kind(&TokenKind::Comma) { break; }
            }
            self.expect(TokenKind::RBracket)?;
        }

        self.expect(TokenKind::RParen)?;
        self.skip_semicolons();
        Ok(Statement::Spawn(SpawnStmt { process_name, reads, writes, span: start.merge(&self.current_span()) }))
    }

    fn parse_grant_stmt(&mut self) -> ParseResult<Statement> {
        let start = self.current_span();
        self.expect(TokenKind::Grant)?;
        let region = self.expect_ident()?;
        self.expect(TokenKind::At)?;
        let access = self.parse_access()?;
        self.expect(TokenKind::To)?;
        let target = self.expect_ident()?;
        self.skip_semicolons();
        Ok(Statement::Grant(GrantStmt { region, access, target, span: start.merge(&self.current_span()) }))
    }

    fn parse_revoke_stmt(&mut self) -> ParseResult<Statement> {
        let start = self.current_span();
        self.expect(TokenKind::Revoke)?;
        let region = self.expect_ident()?;
        self.expect(TokenKind::From)?;
        let target = self.expect_ident()?;
        self.skip_semicolons();
        Ok(Statement::Revoke(RevokeStmt { region, target, span: start.merge(&self.current_span()) }))
    }

    fn parse_migrate_stmt(&mut self) -> ParseResult<Statement> {
        let start = self.current_span();
        self.expect(TokenKind::Migrate)?;
        let region = self.expect_ident()?;
        self.expect(TokenKind::From)?;
        let from_tier = self.parse_tier()?;
        self.expect(TokenKind::To)?;
        let to_tier = self.parse_tier()?;
        self.skip_semicolons();
        Ok(Statement::Migrate(MigrateStmt { region, from_tier, to_tier, span: start.merge(&self.current_span()) }))
    }

    fn parse_expr(&mut self) -> ParseResult<Expr> {
        self.parse_or_expr()
    }

    fn parse_or_expr(&mut self) -> ParseResult<Expr> {
        let left = self.parse_and_expr()?;
        if matches!(self.peek(), TokenKind::Or) {
            self.advance();
            let right = self.parse_and_expr()?;
            Ok(Expr::BinaryOp(Box::new(left), BinOp::Or, Box::new(right), self.current_span()))
        } else {
            Ok(left)
        }
    }

    fn parse_and_expr(&mut self) -> ParseResult<Expr> {
        let left = self.parse_comparison_expr()?;
        if matches!(self.peek(), TokenKind::And) {
            self.advance();
            let right = self.parse_comparison_expr()?;
            Ok(Expr::BinaryOp(Box::new(left), BinOp::And, Box::new(right), self.current_span()))
        } else {
            Ok(left)
        }
    }

    fn parse_comparison_expr(&mut self) -> ParseResult<Expr> {
        let left = self.parse_additive_expr()?;
        let op = match self.peek() {
            TokenKind::EqEq => Some(BinOp::Eq),
            TokenKind::Neq => Some(BinOp::Neq),
            TokenKind::Lt => Some(BinOp::Lt),
            TokenKind::Gt => Some(BinOp::Gt),
            TokenKind::Lte => Some(BinOp::Lte),
            TokenKind::Gte => Some(BinOp::Gte),
            _ => None,
        };
        if let Some(op) = op {
            self.advance();
            let right = self.parse_additive_expr()?;
            Ok(Expr::BinaryOp(Box::new(left), op, Box::new(right), self.current_span()))
        } else {
            Ok(left)
        }
    }

    fn parse_additive_expr(&mut self) -> ParseResult<Expr> {
        let mut left = self.parse_multiplicative_expr()?;
        loop {
            let op = match self.peek() {
                TokenKind::Plus => BinOp::Add,
                TokenKind::Minus => BinOp::Sub,
                _ => break,
            };
            self.advance();
            let right = self.parse_multiplicative_expr()?;
            left = Expr::BinaryOp(Box::new(left), op, Box::new(right), self.current_span());
        }
        Ok(left)
    }

    fn parse_multiplicative_expr(&mut self) -> ParseResult<Expr> {
        let mut left = self.parse_unary_expr()?;
        loop {
            let op = match self.peek() {
                TokenKind::Star => BinOp::Mul,
                TokenKind::Slash => BinOp::Div,
                TokenKind::Percent => BinOp::Mod,
                TokenKind::Caret => BinOp::Pow,
                TokenKind::Cross => BinOp::Mul, // × same as *
                _ => break,
            };
            self.advance();
            let right = self.parse_unary_expr()?;
            left = Expr::BinaryOp(Box::new(left), op, Box::new(right), self.current_span());
        }
        Ok(left)
    }

    fn parse_unary_expr(&mut self) -> ParseResult<Expr> {
        match self.peek() {
            TokenKind::Minus => {
                self.advance();
                let expr = self.parse_primary_expr()?;
                Ok(Expr::UnaryOp(UnaryOp::Neg, Box::new(expr), self.current_span()))
            }
            TokenKind::Not => {
                self.advance();
                let expr = self.parse_primary_expr()?;
                Ok(Expr::UnaryOp(UnaryOp::Not, Box::new(expr), self.current_span()))
            }
            _ => self.parse_primary_expr(),
        }
    }

    fn parse_primary_expr(&mut self) -> ParseResult<Expr> {
        let tok = self.peek().clone();
        let span = self.current_span();
        match tok {
            TokenKind::IntLit(v) => { self.advance(); Ok(Expr::IntLit(v, span)) }
            TokenKind::FloatLit(v) => { self.advance(); Ok(Expr::FloatLit(v, span)) }
            TokenKind::ColorLit(v) => { self.advance(); Ok(Expr::ColorLit(v, span)) }
            TokenKind::StringLit(ref s) => { let s = s.clone(); self.advance(); Ok(Expr::StringLit(s, span)) }
            TokenKind::BoolLit(v) => { self.advance(); Ok(Expr::BoolLit(v, span)) }
            TokenKind::IntWithUnit(v, ref u) => { let v = v; let u = u.clone(); self.advance(); Ok(Expr::IntWithUnit(v, u, span)) }
            TokenKind::FloatWithUnit(v, ref u) => { let v = v; let u = u.clone(); self.advance(); Ok(Expr::FloatWithUnit(v, u, span)) }
            TokenKind::Ident(_) => self.parse_ident_or_call_expr(),
            TokenKind::LParen => {
                self.advance();
                let expr = self.parse_expr()?;
                self.expect(TokenKind::RParen)?;
                Ok(expr)
            }
            TokenKind::LBracket => self.parse_element_literal(),
            _ => Err(ParseError {
                message: format!("expected expression, got {}", tok),
                span,
            }),
        }
    }

    fn parse_ident_or_call_expr(&mut self) -> ParseResult<Expr> {
        let name = self.expect_ident()?;
        let span = name.1.clone();

        // Check for function call: ident(...)
        if matches!(self.peek(), TokenKind::LParen) {
            self.advance();
            let mut args = Vec::new();
            if !matches!(self.peek(), TokenKind::RParen) {
                args.push(self.parse_expr()?);
                while self.match_kind(&TokenKind::Comma) {
                    args.push(self.parse_expr()?);
                }
            }
            self.expect(TokenKind::RParen)?;
            return Ok(Expr::Call(name, args, span));
        }

        // Check for region access: ident[...]
        if matches!(self.peek(), TokenKind::LBracket) {
            self.advance();
            let axes = self.parse_axis_accesses()?;
            self.expect(TokenKind::RBracket)?;
            return Ok(Expr::RegionAccess { region: name, axes, span });
        }

        // Check for component access: ident.component
        if matches!(self.peek(), TokenKind::Dot) {
            self.advance();
            let comp = match self.advance().kind {
                TokenKind::Ident(s) => s,
                _ => return Err(ParseError { message: "expected component name".to_string(), span: self.current_span() }),
            };
            return Ok(Expr::ComponentAccess {
                object: Box::new(Expr::Ident(name)),
                component: comp,
                span,
            });
        }

        Ok(Expr::Ident(name))
    }

    fn parse_axis_accesses(&mut self) -> ParseResult<Vec<AxisAccess>> {
        let mut axes = Vec::new();
        axes.push(self.parse_axis_access()?);
        while self.match_kind(&TokenKind::Comma) {
            axes.push(self.parse_axis_access()?);
        }
        Ok(axes)
    }

    fn parse_axis_access(&mut self) -> ParseResult<AxisAccess> {
        if matches!(self.peek(), TokenKind::Star) {
            self.advance();
            return Ok(AxisAccess::All);
        }
        let expr = self.parse_expr()?;
        if matches!(self.peek(), TokenKind::DoubleDot) {
            self.advance();
            let end = if !matches!(self.peek(), TokenKind::Comma | TokenKind::RBracket) {
                Some(self.parse_expr()?)
            } else {
                None
            };
            Ok(AxisAccess::Range(Some(expr), end))
        } else {
            Ok(AxisAccess::Index(expr))
        }
    }

    fn parse_element_literal(&mut self) -> ParseResult<Expr> {
        self.expect(TokenKind::LBracket)?;
        // Could be a matrix literal or element literal
        // [r: 255, g: 0, b: 0, a: 255] or [[1, 0], [0, 1]]
        // Try element literal first
        let first = self.parse_expr()?;
        if matches!(self.peek(), TokenKind::Colon) {
            // Element literal: [r: 255, g: 0, b: 0, a: 255]
            self.advance(); // consume ':'
            let first_val = self.parse_expr()?;
            let mut components = vec![(match &first {
                Expr::Ident(id) => id.0.clone(),
                _ => "c0".to_string(),
            }, first_val)];
            while self.match_kind(&TokenKind::Comma) {
                let name = self.expect_ident()?;
                self.expect(TokenKind::Colon)?;
                let val = self.parse_expr()?;
                components.push((name.0, val));
            }
            self.expect(TokenKind::RBracket)?;
            Ok(Expr::ElementLit(components, self.current_span()))
        } else if matches!(self.peek(), TokenKind::Comma) {
            // Could be inner row of matrix literal or just a list
            let mut row = vec![first];
            while self.match_kind(&TokenKind::Comma) {
                row.push(self.parse_expr()?);
            }
            // Check for matrix: [row, ...], [row, ...]]
            if matches!(self.peek(), TokenKind::RBracket) {
                self.advance();
                // Could be single-row matrix or just element list
                // Treat as 1-row matrix
                Ok(Expr::MatrixLiteral(vec![row], self.current_span()))
            } else {
                Err(ParseError { message: "expected ]".to_string(), span: self.current_span() })
            }
        } else {
            self.expect(TokenKind::RBracket)?;
            // Single element
            Ok(Expr::MatrixLiteral(vec![vec![first]], self.current_span()))
        }
    }

    fn parse_type(&mut self) -> ParseResult<Type> {
        match self.peek() {
            TokenKind::U8x4 => { self.advance(); Ok(Type::ElementFormat(ElementFormat::U8x4)) }
            TokenKind::F32x4 => { self.advance(); Ok(Type::ElementFormat(ElementFormat::F32x4)) }
            TokenKind::U16x4 => { self.advance(); Ok(Type::ElementFormat(ElementFormat::U16x4)) }
            TokenKind::Raw => { self.advance(); Ok(Type::Scalar(ScalarType::U8)) } // approximate
            TokenKind::Ident(s) if s == "u8" => { self.advance(); Ok(Type::Scalar(ScalarType::U8)) }
            TokenKind::Ident(s) if s == "u16" => { self.advance(); Ok(Type::Scalar(ScalarType::U16)) }
            TokenKind::Ident(s) if s == "u32" => { self.advance(); Ok(Type::Scalar(ScalarType::U32)) }
            TokenKind::Ident(s) if s == "u64" => { self.advance(); Ok(Type::Scalar(ScalarType::U64)) }
            TokenKind::Ident(s) if s == "i8" => { self.advance(); Ok(Type::Scalar(ScalarType::I8)) }
            TokenKind::Ident(s) if s == "i16" => { self.advance(); Ok(Type::Scalar(ScalarType::I16)) }
            TokenKind::Ident(s) if s == "i32" => { self.advance(); Ok(Type::Scalar(ScalarType::I32)) }
            TokenKind::Ident(s) if s == "i64" => { self.advance(); Ok(Type::Scalar(ScalarType::I64)) }
            TokenKind::Ident(s) if s == "f32" => { self.advance(); Ok(Type::Scalar(ScalarType::F32)) }
            TokenKind::Ident(s) if s == "f64" => { self.advance(); Ok(Type::Scalar(ScalarType::F64)) }
            TokenKind::Ident(s) if s == "bool" => { self.advance(); Ok(Type::Scalar(ScalarType::Bool)) }
            TokenKind::Region => Ok(Type::Region(self.parse_region_type()?)),
            TokenKind::Ident(s) if s.starts_with(char::is_uppercase) => {
                let name = self.expect_ident()?;
                Ok(Type::Param(name))
            }
            _ => Err(ParseError {
                message: format!("expected type, got {}", self.peek()),
                span: self.current_span(),
            }),
        }
    }

    fn parse_predicate(&mut self) -> ParseResult<Predicate> {
        self.parse_or_predicate()
    }

    fn parse_or_predicate(&mut self) -> ParseResult<Predicate> {
        let left = self.parse_and_predicate()?;
        if matches!(self.peek(), TokenKind::Or) {
            self.advance();
            let right = self.parse_and_predicate()?;
            Ok(Predicate::And(Box::new(left), Box::new(right))) // Note: 'or' should be Or
        } else {
            Ok(left)
        }
    }

    fn parse_and_predicate(&mut self) -> ParseResult<Predicate> {
        // Simplified: just parse a comparison for now
        let left = self.parse_expr()?;
        match self.peek() {
            TokenKind::EqEq => {
                self.advance();
                let right = self.parse_expr()?;
                Ok(Predicate::Compare(left, CmpOp::Eq, right))
            }
            TokenKind::Neq => {
                self.advance();
                let right = self.parse_expr()?;
                Ok(Predicate::Compare(left, CmpOp::Neq, right))
            }
            TokenKind::Lte => {
                self.advance();
                let right = self.parse_expr()?;
                Ok(Predicate::Compare(left, CmpOp::Lte, right))
            }
            TokenKind::Gte => {
                self.advance();
                let right = self.parse_expr()?;
                Ok(Predicate::Compare(left, CmpOp::Gte, right))
            }
            TokenKind::Lt => {
                self.advance();
                let right = self.parse_expr()?;
                Ok(Predicate::Compare(left, CmpOp::Lt, right))
            }
            TokenKind::Gt => {
                self.advance();
                let right = self.parse_expr()?;
                Ok(Predicate::Compare(left, CmpOp::Gt, right))
            }
            TokenKind::ApproxEq => {
                self.advance();
                let right = self.parse_expr()?;
                let tolerance = if matches!(self.peek(), TokenKind::FloatLit(_)) {
                    let tol = match self.advance().kind {
                        TokenKind::FloatLit(v) => Some(v),
                        _ => None,
                    };
                    tol
                } else {
                    None
                };
                Ok(Predicate::Approx(left, right, tolerance))
            }
            _ => Ok(Predicate::Compare(left, CmpOp::Eq, Expr::BoolLit(true, Span::zero()))),
        }
    }

    fn parse_predicate_list(&mut self) -> ParseResult<Vec<Predicate>> {
        let mut preds = Vec::new();
        preds.push(self.parse_predicate()?);
        while self.match_kind(&TokenKind::Semicolon) {
            if matches!(self.peek(), TokenKind::Ensures | TokenKind::End | TokenKind::When | TokenKind::Every | TokenKind::Temporal) {
                break;
            }
            preds.push(self.parse_predicate()?);
        }
        Ok(preds)
    }

    fn parse_builtin_stmt(&mut self) -> ParseResult<Statement> {
        let start = self.current_span();
        match self.peek() {
            TokenKind::Project => {
                self.advance();
                let source = self.expect_ident()?;
                self.expect(TokenKind::Through)?;
                let transform = self.expect_ident()?;
                self.expect(TokenKind::Onto)?;
                let target = self.expect_ident()?;
                self.skip_semicolons();
                Ok(Statement::Builtin(BuiltinStmt::Project { source, transform, target, span: start.merge(&self.current_span()) }))
            }
            TokenKind::Blend => {
                self.advance();
                let source = self.expect_ident()?;
                self.expect(TokenKind::Over)?;
                let over = self.expect_ident()?;
                let into = if self.match_kind(&TokenKind::Into) {
                    Some(self.expect_ident()?)
                } else {
                    None
                };
                self.skip_semicolons();
                Ok(Statement::Builtin(BuiltinStmt::Blend { source, over, into, span: start.merge(&self.current_span()) }))
            }
            TokenKind::Evolve => {
                self.advance();
                let state = self.expect_ident()?;
                self.expect(TokenKind::By)?;
                let hamiltonian = self.expect_ident()?;
                self.expect(TokenKind::For)?;
                let dt = self.parse_expr()?;
                self.skip_semicolons();
                Ok(Statement::Builtin(BuiltinStmt::Evolve { state, hamiltonian, dt, span: start.merge(&self.current_span()) }))
            }
            TokenKind::Convolve => {
                self.advance();
                let kernel = self.expect_ident()?;
                self.expect(TokenKind::Over)?;
                let over = self.expect_ident()?;
                let into = if self.match_kind(&TokenKind::Into) {
                    Some(self.expect_ident()?)
                } else {
                    None
                };
                let activation = if self.match_kind(&TokenKind::WithKw) {
                    match self.advance().kind {
                        TokenKind::Ident(s) if s == "relu" => Some("relu".to_string()),
                        TokenKind::Ident(s) if s == "sigmoid" => Some("sigmoid".to_string()),
                        other => Some(format!("{:?}", other)),
                    }
                } else {
                    None
                };
                self.skip_semicolons();
                Ok(Statement::Builtin(BuiltinStmt::Convolve { kernel, over, into, activation, span: start.merge(&self.current_span()) }))
            }
            TokenKind::Clear => {
                self.advance();
                let region = self.expect_ident()?;
                self.expect(TokenKind::To)?;
                let color = self.parse_expr()?;
                self.skip_semicolons();
                Ok(Statement::Builtin(BuiltinStmt::Clear { region, color, span: start.merge(&self.current_span()) }))
            }
            TokenKind::Swap => {
                self.advance();
                let a = self.expect_ident()?;
                self.expect(TokenKind::WithKw)?;
                let b = self.expect_ident()?;
                self.skip_semicolons();
                Ok(Statement::Builtin(BuiltinStmt::Swap { a, b, span: start.merge(&self.current_span()) }))
            }
            TokenKind::Persist => {
                self.advance();
                let region = self.expect_ident()?;
                self.skip_semicolons();
                Ok(Statement::Builtin(BuiltinStmt::Persist { region, span: start.merge(&self.current_span()) }))
            }
            TokenKind::Reshape => {
                self.advance();
                let source = self.expect_ident()?;
                self.expect(TokenKind::Into)?;
                let into = self.expect_ident()?;
                self.skip_semicolons();
                Ok(Statement::Builtin(BuiltinStmt::Reshape { source, into, span: start.merge(&self.current_span()) }))
            }
            TokenKind::Fill => {
                self.advance();
                let region = self.expect_ident()?;
                self.expect(TokenKind::WithKw)?;
                // consume "color" keyword
                let _color_kw = self.expect_ident()?;
                let color = self.parse_expr()?;
                let radius = if self.peek_is_ident() {
                    let _kw = self.expect_ident()?;
                    Some(self.parse_expr()?)
                } else { None };
                let shadow = if self.peek_is_ident() {
                    let _kw = self.expect_ident()?;
                    Some(self.parse_expr()?)
                } else { None };
                self.skip_semicolons();
                Ok(Statement::Builtin(BuiltinStmt::Fill { region, color, radius, shadow, span: start.merge(&self.current_span()) }))
            }
            _ => Err(ParseError {
                message: format!("expected builtin statement, got {}", self.peek()),
                span: start,
            }),
        }
    }

    fn parse_ident_stmt(&mut self) -> ParseResult<Statement> {
        let name = self.expect_ident()?;
        let span = name.1.clone();

        // Region write: name[x: 0, y: 0] := expr
        if matches!(self.peek(), TokenKind::LBracket) {
            self.advance();
            let axes = self.parse_axis_accesses()?;
            self.expect(TokenKind::RBracket)?;
            self.expect(TokenKind::ColonEq)?;
            let value = self.parse_expr()?;
            self.skip_semicolons();
            return Ok(Statement::RegionWrite(RegionWriteStmt { region: name, axes, value, span }));
        }

        // Assignment: name := expr
        if matches!(self.peek(), TokenKind::ColonEq) {
            self.advance();
            let value = self.parse_expr()?;
            self.skip_semicolons();
            return Ok(Statement::Assign(AssignStmt { name, value, span }));
        }

        // Standalone expression
        Ok(Statement::Expr(Expr::Ident(name)))
    }

    fn parse_temporal_spec(&mut self) -> ParseResult<Item> {
        let start = self.current_span();
        let invariants = self.parse_temporal_spec_inner()?;
        Ok(Item::TemporalSpec(TemporalSpecData { invariants, span: start.merge(&self.current_span()) }))
    }

    fn parse_temporal_spec_inner(&mut self) -> ParseResult<Vec<TemporalExpr>> {
        self.expect(TokenKind::Temporal)?;
        self.expect(TokenKind::Invariant)?; // "invariant" is a keyword
        self.expect(TokenKind::Colon)?;
        let mut invariants = Vec::new();
        invariants.push(self.parse_temporal_expr()?);
        while self.match_kind(&TokenKind::Semicolon) {
            if matches!(self.peek(), TokenKind::End | TokenKind::Eof) {
                break;
            }
            invariants.push(self.parse_temporal_expr()?);
        }
        Ok(invariants)
    }

    fn parse_temporal_expr(&mut self) -> ParseResult<TemporalExpr> {
        let span = self.current_span();
        match self.peek() {
            TokenKind::Always => {
                self.advance();
                self.expect(TokenKind::LParen)?;
                let inner = self.parse_inner_temporal()?;
                self.expect(TokenKind::RParen)?;
                Ok(TemporalExpr::Always(inner, span))
            }
            TokenKind::Eventually => {
                self.advance();
                self.expect(TokenKind::LParen)?;
                let inner = self.parse_inner_temporal()?;
                self.expect(TokenKind::RParen)?;
                Ok(TemporalExpr::Eventually(inner, span))
            }
            _ => Err(ParseError {
                message: format!("expected temporal operator (always/eventually), got {}", self.peek()),
                span,
            }),
        }
    }

    fn parse_inner_temporal(&mut self) -> ParseResult<InnerTemporal> {
        let name = self.expect_ident()?;
        self.expect(TokenKind::Dot)?;
        let prop = self.expect_ident()?;
        match prop.0.as_str() {
            "written" => Ok(InnerTemporal::Written(name)),
            "being_written" => Ok(InnerTemporal::BeingWritten(name)),
            "being_scanned" => Ok(InnerTemporal::BeingScanned(name)),
            _ => Err(ParseError {
                message: format!("expected temporal property (written/being_written/being_scanned), got {}", prop.0),
                span: prop.1,
            }),
        }
    }
}

fn is_keyword(s: &str) -> bool {
    matches!(s,
        "process" | "region" | "reads" | "writes" | "private" | "when" | "every"
        | "on" | "call" | "changes" | "ensures" | "requires" | "end" | "let"
        | "if" | "else" | "for" | "each" | "in" | "while" | "return" | "kill"
        | "and" | "or" | "not" | "self" | "assert" | "assume" | "true" | "false"
    )
}