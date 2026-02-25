# Contributing to Atom OS

First of all, thank you for your interest in contributing to Atom OS!

## Code Style

### Rust
- We follow standard `rustfmt` rules. Run `cargo fmt` before submitting any PR.
- Use `clippy` to catch common mistakes: `cargo clippy -- -D warnings`.

### Python
- Python code should be formatted with `black`.
- We use `mypy` for static type checking.
- Ensure that you follow PEP-8 standards.

## Branching Strategy & Commits
- We use the standard feature branch workflow (e.g., `feature/sync-manager-updates`).
- Keep commits isolated and descriptive. Use conventional commits if possible (e.g., `feat:`, `fix:`, `docs:`).

## Pull Request Process
1. Create a descriptive title and fill out the provided PR template.
2. Ensure all unit and integration tests pass locally.
3. Your code will go through an automated CI pipeline.
4. Wait for approval from at least one core maintainer before merging.

### Adding New Tools or Agents
If you are adding a new MCP tool or a custom Deep Agent definition, make sure you document how it affects the `Security Manager` whitelists and write corresponding integration tests.
