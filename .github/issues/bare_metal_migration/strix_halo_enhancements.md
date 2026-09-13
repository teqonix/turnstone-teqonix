# Strix Halo Cluster Deployment Runbook (Multi-Model Resident Stacking)

Here is the complete, step-by-step runbook to execute during your maintenance window to deploy the new stack cleanly across the cluster.

---

### Pre-Flight Checklist

Before entering the maintenance window:
1. **Branch**: Ensure your local workspace is on the [`dev`](file:///home/turnstone/nerd_projects/turnstone-teqonix) branch (or push `dev` to your upstream remote).
2. **SSH Connectivity**: Ensure you have passwordless SSH or credentials to the cluster nodes (`amd-ai-core-one.lan`, `amd-ai-core-two.lan`, etc.).
3. **Optional Image Pre-pull**: You can pre-cache the container image on the Ryzen nodes ahead of the window to save bandwidth during downtime:
   ```bash
   ssh turnstone@amd-ai-core-one.lan "podman pull docker.io/kyuz0/amd-strix-halo-toolboxes:rocm-10.0-qwen-3.8-flash-next"
   ssh turnstone@amd-ai-core-two.lan "podman pull docker.io/kyuz0/amd-strix-halo-toolboxes:rocm-10.0-qwen-3.8-flash-next"
   ```

---

### Step 1: Sync the Updated Repository to Cluster Nodes

From your local machine in `/home/turnstone/nerd_projects/turnstone-teqonix`:

Run [`sync_repo.sh`](file:///home/turnstone/nerd_projects/turnstone-teqonix/.github/issues/bare_metal_migration/sync_repo.sh) to distribute the new scripts, runners, and manifests across the cluster:

```bash
cd /home/turnstone/nerd_projects/turnstone-teqonix/.github/issues/bare_metal_migration

# Sync to all nodes (or specifically to the Ryzen inference nodes)
./sync_repo.sh ai-core-one
./sync_repo.sh ai-core-two

# (Optional) To sync across the entire cluster:
./sync_repo.sh
```

---

### Step 2: Deploy Ryzen Inference Node #1 (`amd-ai-core-one.lan`)

SSH into the first Ryzen node:
```bash
ssh turnstone@amd-ai-core-one.lan
```

1. **Drain/Stop Legacy Services**:
   Stop any running PAIR tmux session or old inference containers:
   ```bash
   sudo systemctl stop nvpair.service 2>/dev/null || true
   sudo -u teqonix tmux kill-session -t pair 2>/dev/null || true
   podman stop pair-llama-engine 2>/dev/null || docker stop pair-llama-engine 2>/dev/null || true
   ```

2. **Execute Deployment**:
   Run [`deploy_ryzen_node.sh`](file:///home/turnstone/nerd_projects/turnstone-teqonix/.github/issues/bare_metal_migration/deploy_ryzen_node.sh) with `--engine lmstudio` (which sets up our ROCm 10.0 Llama drop-in runner and aliases it to LM Studio):
   ```bash
   cd ~/nerd_projects/turnstone-teqonix/.github/issues/bare_metal_migration
   sudo -E ./deploy_ryzen_node.sh --engine lmstudio
   ```
   > [!NOTE]
   > If you still want Ollama side-by-side on port 11434, pass `--engine both`.

3. **Verify Local Node #1 Health**:
   - **Check container**:
     ```bash
     podman ps  # should show pair-llama-engine running
     ```
   - **Check OpenAI `/v1/models` endpoint on port 1235**:
     ```bash
     curl -s http://127.0.0.1:1235/v1/models | jq .
     ```
   - **Run a quick test generation**:
     ```bash
     curl -s http://127.0.0.1:1235/v1/chat/completions \
       -H "Content-Type: application/json" \
       -d '{"messages": [{"role": "user", "content": "Hello AMD Strix Halo!"}], "max_tokens": 30}' | jq .
     ```
   - **Inspect PAIR TUI**:
     ```bash
     sudo -u teqonix tmux attach -t pair
     ```
     *(Detach with `Ctrl+b`, then `d`)*. PAIR should show LM Studio engine active and green.

---

### Step 3: Deploy Ryzen Inference Node #2 (`amd-ai-core-two.lan`)

Repeat the procedure on the second node:
```bash
ssh turnstone@amd-ai-core-two.lan

# 1. Stop old services
sudo systemctl stop nvpair.service 2>/dev/null || true
sudo -u teqonix tmux kill-session -t pair 2>/dev/null || true
podman stop pair-llama-engine 2>/dev/null || docker stop pair-llama-engine 2>/dev/null || true

# 2. Deploy
cd ~/nerd_projects/turnstone-teqonix/.github/issues/bare_metal_migration
sudo -E ./deploy_ryzen_node.sh --engine lmstudio

# 3. Verify
curl -s http://127.0.0.1:1235/v1/models | jq .
```

---

### Step 4: Update Turnstone Node Routing (Debian 12 Container)

Because LiteLLM has been completely retired in favor of PAIR, point your Turnstone worker container to the new inference endpoint:

1. **If deploying a fresh container via [`deploy_turnstone_debian12.sh`](file:///home/turnstone/nerd_projects/turnstone-teqonix/.github/issues/bare_metal_migration/deploy_turnstone_debian12.sh)**:
   ```bash
   LLM_BASE_URL="http://amd-ai-core-one.lan:1235/v1" \
   NODE_ID="turnstone-debian12" \
   sudo -E ./.github/issues/bare_metal_migration/deploy_turnstone_debian12.sh
   ```

2. **If updating an existing running container/host**:
   Update `/etc/turnstone/config.toml` inside the Turnstone container:
   ```toml
   [llm]
   base_url = "http://amd-ai-core-one.lan:1235/v1"
   # or PAIR router port if proxying through PAIR's port
   ```
   Restart the Turnstone server:
   ```bash
   systemctl --user restart turnstone.service 2>/dev/null || docker restart turnstone-node
   ```

---

### Step 5: Full Cluster Validation & Monitoring

1. **Launch the Tmux Monitoring Dashboard**:
   From your management terminal, start the multi-node dashboard:
   ```bash
   cd /home/turnstone/nerd_projects/turnstone-teqonix/.github/issues/bare_metal_migration
   ./tmux-ai-core-monitoring.sh
   ```
   - **Top row**: Shows `all-smi` live GPU VRAM usage, thermals, and clock speeds for Node 1, Node 2, and the Mac M5 Max.
   - **Middle row**: Open SSH shells to each node.
   - **Bottom row**: Real-time PAIR journal logs from Node 1.

2. **Test End-to-End Chat**:
   - Navigate to the Turnstone Web Console (`https://silo-14:9443` or `http://turnstone-coordinator-nerd-projects.lan:8090`).
   - Send a prompt and confirm responses stream back with high tokens-per-second via ROCm 10.0 Direct I/O and Flash Attention.
   - Check `all-smi` to confirm VRAM footprint is compact due to quantized KV cache (`q8_0`).

---

### Rollback Plan (If Needed)

If an unexpected issue occurs on any Ryzen node:
1. Stop the new container runner:
   ```bash
   sudo /usr/local/bin/pair-llama-server stop
   ```
2. Fallback to standard Ollama ROCm:
   ```bash
   cd ~/nerd_projects/turnstone-teqonix/.github/issues/bare_metal_migration
   sudo -E ./deploy_ryzen_node.sh --engine ollama
   ```
3. Re-point `LLM_BASE_URL` back to `http://amd-ai-core-one.lan:11434/v1`.