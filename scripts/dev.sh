#!/usr/bin/env bash
# Start or reattach to the inspirehep dev tmux session.

SESSION="inspirehep"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# If session already exists, just attach
if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "Session '$SESSION' already running. Attaching..."
  tmux attach -t "$SESSION"
  exit 0
fi

# Ensure infrastructure is running (including MinIO)
docker compose -f "$ROOT/docker-compose.services.yml" -f "$ROOT/docker-compose.override.yml" up -d es mq db cache s3

# Create new detached session — first window: backend
tmux new-session -d -s "$SESSION" -n "backend" -x 220 -y 50
tmux send-keys -t "$SESSION:backend" "cd '$ROOT/backend' && ./scripts/server" Enter

# Second window: UI
tmux new-window -t "$SESSION" -n "ui"
tmux send-keys -t "$SESSION:ui" "cd '$ROOT/ui' && HOST=0.0.0.0 NODE_OPTIONS=--openssl-legacy-provider yarn start" Enter

# Third window: free shell at project root (for git, CLI commands, etc.)
tmux new-window -t "$SESSION" -n "shell"
tmux send-keys -t "$SESSION:shell" "cd '$ROOT'" Enter

# Focus backend window and attach
tmux select-window -t "$SESSION:backend"
tmux attach -t "$SESSION"
