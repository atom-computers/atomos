# MCP Server Integration

## Overview
The Model Context Protocol (MCP) is deeply embedded in Atom OS. The `sync-manager` actively listens for generic MCP services on loopback and tailscale subnets using mDNS.

## Connecting an MCP Server
To manually map an MCP server (e.g., a Github API MCP, or a Linear MCP node script), add it to the sync configuration:
```yaml
# /etc/atomos/sync/config.yaml
mcp_sources:
  - name: "github"
    endpoint: "http://localhost:8000/mcp"
    type: "rest"
```
The sync manager handles calling `listTools` and `listResources`, and dumps the resultant schema into SurrealDB so the Deep Agent knows how to use them contextually.
