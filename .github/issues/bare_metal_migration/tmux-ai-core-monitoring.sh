#!/bin/bash

# AI Cluster Monitoring Tmux Session Manager
# Sets up a 3-node monitoring dashboard (Top: all-smi, Mid: SSH Shells, Bot: LiteLLM Logs & Help Screen)

SESSION="ai-cluster"
WINDOW="MONITOR"

# Host Definitions
HOST1="teqonix@amd-ai-core-one.lan"
HOST2="teqonix@amd-ai-core-two.lan"
HOST3="teqonix@mbp-ai-core.lan"
HOST_PROXY="turnstone@litellm-proxy.lan"

# 0. Idempotency: Destroy session if it already exists
if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "Tmux session '$SESSION' already exists. Destroying it before recreating..."
    tmux kill-session -t "$SESSION"
fi

# 1. Start the session detached and capture the root top-left pane ID
P_TOP_1=$(tmux new-session -d -s "$SESSION" -n "$WINDOW" -P -F "#{pane_id}")

# 2. Layout Construction using dynamic pane IDs
# Create the bottom row (allocate ~25% height) and split into Proxy logs & Help screen
P_BOT_PROXY=$(tmux split-window -v -p 25 -t "$P_TOP_1" -P -F "#{pane_id}")
P_BOT_LITELLM=$(tmux split-window -h -p 25 -t "$P_BOT_PROXY" -P -F "#{pane_id}")
P_BOT_HELP=$(tmux split-window -h -p 30 -t "$P_BOT_LITELLM" -P -F "#{pane_id}")

# Split the top row into 3 columns (Host 1, Host 2, Host 3)
P_TOP_2=$(tmux split-window -h -p 67 -t "$P_TOP_1" -P -F "#{pane_id}")
P_TOP_3=$(tmux split-window -h -p 50 -t "$P_TOP_2" -P -F "#{pane_id}")

# Split each top column vertically to create the middle row shells (50% height each)
P_MID_1=$(tmux split-window -v -p 50 -t "$P_TOP_1" -P -F "#{pane_id}")
P_MID_2=$(tmux split-window -v -p 50 -t "$P_TOP_2" -P -F "#{pane_id}")
P_MID_3=$(tmux split-window -v -p 50 -t "$P_TOP_3" -P -F "#{pane_id}")

# 3. Send Commands

# --- TOP ROW: all-smi monitors (using ssh -t for TTY allocation) ---
tmux send-keys -t "$P_TOP_1" "ssh -t $HOST1 'sudo /home/linuxbrew/.linuxbrew/bin/all-smi || sudo all-smi'" C-m
tmux send-keys -t "$P_TOP_2" "ssh -t $HOST2 'sudo /home/linuxbrew/.linuxbrew/bin/all-smi || sudo all-smi'" C-m
tmux send-keys -t "$P_TOP_3" "ssh -t $HOST3 'export PATH=\"/opt/homebrew/bin:/usr/local/bin:\$HOME/.cargo/bin:\$PATH\"; all-smi'" C-m

# --- MIDDLE ROW: Interactive SSH shells ---
tmux send-keys -t "$P_MID_1" "ssh $HOST1" C-m
tmux send-keys -t "$P_MID_2" "ssh $HOST2" C-m
tmux send-keys -t "$P_MID_3" "ssh $HOST3" C-m

# --- BOTTOM ROW: LiteLLM Proxy Logs & Help Screen ---
tmux send-keys -t "$P_BOT_PROXY" "ssh -t $HOST_PROXY 'tail -f /etc/litellm/unified_proxy.log'" C-m
tmux send-keys -t "$P_BOT_LITELLM" "ssh -t $HOST_PROXY 'sudo journalctl -f -n 100 --grep=litellm'" C-m
tmux send-keys -t "$P_BOT_HELP" "clear && cat << 'EOF'
################################################################################
#                      AI CLUSTER MONITORING DASHBOARD                         #
################################################################################
#                                                                              #
#  LAYOUT:                                                                     #
#  [ Host 1: all-smi ] [ Host 2: all-smi ] [ Host 3: all-smi ]  <-- TOP ROW    #
#  [ Host 1: Shell   ] [ Host 2: Shell   ] [ Host 3: Shell   ]  <-- MID ROW    #
#  [ LiteLLM Proxy Logs                  ] [ Help Screen     ]  <-- BOT ROW    #
#                                                                              #
#  TMUX NAVIGATION:                                                            #
#  - Switch Pane:  Ctrl+b + Arrow Keys                                         #
#  - Zoom Pane:    Ctrl+b + z                                                  #
#  - Detach:       Ctrl+b + d                                                  #
#  - Close Pane:   Ctrl+d or type 'exit'                                       #
################################################################################
EOF
" C-m

# Attach to session if running interactively
if [ -t 0 ]; then
    tmux attach-session -t "$SESSION"
fi
