#!/bin/bash
export PATH="$HOME/.bun/bin:$HOME/.local/bin:$PATH"
SESSION="claude"
WORK_DIR=/home/ubuntu/claude/jerome

tmux kill-session -t $SESSION 2>/dev/null || true

tmux new-session -d -s $SESSION -c "$WORK_DIR"

tmux send-keys -t $SESSION "claude" Enter

echo "⏳ Waiting for Claude CLI to start..."
for i in {1..20}; do
    sleep 0.5
    if tmux capture-pane -t $SESSION -p | grep -qE "(claude|> |╭)"; then
        echo "✅ Claude CLI ready (after ${i}x0.5s)"
        break
    fi
    if [ $i -eq 20 ]; then
        echo "⚠️ Timeout waiting for Claude CLI (10s)"
        echo "   Check manually: tmux attach -t $SESSION"
        exit 1
    fi
done

sleep 1

tmux send-keys -t $SESSION "/remote-control"
sleep 0.3
tmux send-keys -t $SESSION Enter
