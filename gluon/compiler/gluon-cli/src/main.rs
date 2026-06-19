use std::env;
use std::fs;
use std::process;

use gluon_lexer::Lexer;
use gluon_parser::Parser;
use gluon_resolver::Resolver;
use gluon_checker::Checker;

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage: gluon <command> [options]");
        eprintln!();
        eprintln!("Commands:");
        eprintln!("  parse <file.g>       Parse a Gluon source file and print the AST");
        eprintln!("  lex <file.g>         Lex a Gluon source file and print tokens");
        eprintln!("  resolve <file.g>     Parse and resolve a Gluon source file");
        eprintln!("  check <file.g>       Type-check a Gluon source file");
        eprintln!("  verify <file.g>      Verify contracts in a Gluon source file (not yet implemented)");
        eprintln!("  build <file.g>       Compile a Gluon source file to WASM (not yet implemented)");
        eprintln!("  model-check <file.g>  Temporal model checking (not yet implemented)");
        process::exit(1);
    }

    let command = &args[1];
    let filepath = if args.len() > 2 {
        &args[2]
    } else {
        eprintln!("Error: expected file path");
        process::exit(1);
    };

    let source = match fs::read_to_string(filepath) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("Error reading '{}': {}", filepath, e);
            process::exit(1);
        }
    };

    match command.as_str() {
        "lex" => cmd_lex(&source),
        "parse" => cmd_parse(&source),
        "resolve" => cmd_resolve(&source),
        "check" => cmd_check(&source),
        "verify" => {
            eprintln!("Contract verification is not yet implemented");
            process::exit(1);
        }
        "build" => {
            eprintln!("WASM compilation is not yet implemented");
            process::exit(1);
        }
        "model-check" => {
            eprintln!("Temporal model checking is not yet implemented");
            process::exit(1);
        }
        _ => {
            eprintln!("Unknown command: {}", command);
            process::exit(1);
        }
    }
}

fn cmd_lex(source: &str) {
    let tokens = match Lexer::new(source).tokenize() {
        Ok(tokens) => tokens,
        Err(errors) => {
            for err in &errors {
                eprintln!("{}", err);
            }
            process::exit(1);
        }
    };

    for token in &tokens {
        println!("{:>4}:{:<3}  {}", token.span.line, token.span.col, token.kind);
    }

    println!();
    println!("{} tokens", tokens.len());
}

fn cmd_parse(source: &str) {
    let tokens = match Lexer::new(source).tokenize() {
        Ok(tokens) => tokens,
        Err(errors) => {
            for err in &errors {
                eprintln!("{}", err);
            }
            process::exit(1);
        }
    };

    let module = match Parser::new(tokens).parse_module() {
        Ok(module) => module,
        Err(err) => {
            eprintln!("{}", err);
            process::exit(1);
        }
    };

    print_module(&module, 0);
}

fn cmd_resolve(source: &str) {
    let tokens = match Lexer::new(source).tokenize() {
        Ok(tokens) => tokens,
        Err(errors) => {
            for err in &errors {
                eprintln!("{}", err);
            }
            process::exit(1);
        }
    };

    let module = match Parser::new(tokens).parse_module() {
        Ok(module) => module,
        Err(err) => {
            eprintln!("{}", err);
            process::exit(1);
        }
    };

    let mut resolver = Resolver::new();
    match resolver.resolve(&module) {
        Ok(resolved) => {
            println!("Resolution successful:");
            for item in &resolved.items {
                match item {
                    gluon_resolver::ResolvedItem::RegionDecl(decl) => {
                        println!("  region {} (resolved)", decl.name);
                    }
                    gluon_resolver::ResolvedItem::ProcessDecl(proc) => {
                        println!("  process {} (resolved)", proc.name);
                        for (name, _) in &proc.reads {
                            println!("    reads {}", name);
                        }
                        for (name, _) in &proc.writes {
                            println!("    writes {}", name);
                        }
                    }
                    gluon_resolver::ResolvedItem::TemporalSpec(spec) => {
                        println!("  temporal invariant ({} invariants)", spec.invariants.len());
                    }
                }
            }
        }
        Err(errors) => {
            for err in &errors {
                eprintln!("{}", err);
            }
            process::exit(1);
        }
    }
}

fn cmd_check(source: &str) {
    let tokens = match Lexer::new(source).tokenize() {
        Ok(tokens) => tokens,
        Err(errors) => {
            for err in &errors {
                eprintln!("{}", err);
            }
            process::exit(1);
        }
    };

    let module = match Parser::new(tokens).parse_module() {
        Ok(module) => module,
        Err(err) => {
            eprintln!("{}", err);
            process::exit(1);
        }
    };

    let mut resolver = Resolver::new();
    let resolved = match resolver.resolve(&module) {
        Ok(r) => r,
        Err(errors) => {
            for err in &errors {
                eprintln!("{}", err);
            }
            process::exit(1);
        }
    };

    let mut checker = Checker::new();
    match checker.check(&module, &resolved) {
        Ok(()) => {
            println!("Type checking passed: no errors found.");
        }
        Err(errors) => {
            for err in &errors {
                eprintln!("{}", err);
            }
            process::exit(1);
        }
    }
}

fn print_module(module: &gluon_parser::ast::Module, indent: usize) {
    let pad = "  ".repeat(indent);
    println!("{}Module ({} items):", pad, module.items.len());
    for item in &module.items {
        print_item(item, indent + 1);
    }
}

fn print_item(item: &gluon_parser::ast::Item, indent: usize) {
    let pad = "  ".repeat(indent);
    match item {
        gluon_parser::ast::Item::RegionDecl(decl) => {
            println!("{}RegionDecl:", pad);
            println!("{}  name: {}", pad, decl.name.0);
            println!("{}  kind: {:?}", pad, decl.region_type.kind);
            println!("{}  dimensions: {} specs", pad, decl.region_type.dimensions.len());
            for dim in &decl.region_type.dimensions {
                println!("{}    {}:{:?}{}", pad, dim.name.0, dim.size, dim.unit);
            }
            println!("{}  format: {:?}", pad, decl.region_type.format);
            println!("{}  tier: {:?}", pad, decl.region_type.tier);
            println!("{}  access: {:?}", pad, decl.region_type.access);
            if !decl.invariants.is_empty() {
                println!("{}  invariants: {} predicates", pad, decl.invariants.len());
            }
        }
        gluon_parser::ast::Item::ProcessDecl(proc) => {
            println!("{}ProcessDecl:", pad);
            println!("{}  name: {}", pad, proc.name.0);
            println!("{}  reads: {} regions", pad, proc.reads.len());
            for (name, access) in &proc.reads {
                println!("{}    {}{:?}", pad, name.0, access.as_ref().map(|a| format!(" @ {:?}", a)).unwrap_or_default());
            }
            println!("{}  writes: {} regions", pad, proc.writes.len());
            for (name, access) in &proc.writes {
                println!("{}    {}{:?}", pad, name.0, access.as_ref().map(|a| format!(" @ {:?}", a)).unwrap_or_default());
            }
            println!("{}  privates: {}", pad, proc.privates.len());
            println!("{}  react_blocks: {}", pad, proc.react_blocks.len());
            for block in &proc.react_blocks {
                match block {
                    gluon_parser::ast::ReactBlock::When(w) => {
                        let triggers: Vec<&str> = w.triggers.iter().map(|t| t.0.as_str()).collect();
                        println!("{}    when {} changes: {} stmts", pad, triggers.join(" or "), w.body.len());
                    }
                    gluon_parser::ast::ReactBlock::Every(e) => {
                        println!("{}    every {}{}: {} stmts", pad, e.duration, e.unit, e.body.len());
                    }
                    gluon_parser::ast::ReactBlock::Call(c) => {
                        println!("{}    on call({}): {} stmts", pad, c.name.0, c.body.len());
                    }
                }
            }
            if !proc.ensures.is_empty() {
                println!("{}  ensures: {} predicates", pad, proc.ensures.len());
            }
            if !proc.requires.is_empty() {
                println!("{}  requires: {} predicates", pad, proc.requires.len());
            }
            if !proc.temporal_invariants.is_empty() {
                println!("{}  temporal_invariants: {}", pad, proc.temporal_invariants.len());
            }
        }
        gluon_parser::ast::Item::TemporalSpec(spec) => {
            println!("{}TemporalSpec: {} invariants", pad, spec.invariants.len());
        }
    }
}