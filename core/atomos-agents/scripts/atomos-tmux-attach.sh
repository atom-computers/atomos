#!/bin/bash
# Launched as SHELL= when opening cosmic-term for the agent session.
# Uses the shared socket so the desktop user can attach to the same
# tmux session that the agent service (running as root) created.
SOCK=/tmp/atomos-agent.sock
exec tmux -S "$SOCK" attach-session -t atomos-agent 2>/dev/null \
  || exec tmux -S "$SOCK" new-session -s atomos-agent
