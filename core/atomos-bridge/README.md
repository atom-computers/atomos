# Atom OS Bridge (`atomos-bridge`)

## Overview
This crate is the Rust client implementation for the Python/Rust gRPC connection. It acts as the conduit between the user-facing COSMIC Desktop applets (or Rust Core managers) and the Python-based AI framework (`atomos-agents`).

## Protocol
Check out `docs/bridge_protocol.md` for information on the `.proto` service definitions.
It handles unary callbacks (for tool schemas) and bidirectional streams (for agent conversation responses, planning step updates, and sub-tool invocation).
