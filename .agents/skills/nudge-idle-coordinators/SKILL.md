---
name: nudge-idle-coordinators
description: Inspect active Turnstone coordinator sessions to detect stuck or improperly idled coordinators and send nudges to resume execution.
---

# Nudge Idle Coordinators Skill

This skill guides an agent on how to use `workspace/turnstone-teqonix/scripts/coordinator_inspector.py` to inspect active Turnstone coordinator sessions, determine if any session has idled improperly with unresolved work, and send a nudge to prompt the coordinator to resume execution.

## When to Use This Skill

Use this skill when:
- Monitoring Turnstone coordinator sessions across worker nodes and coordinator servers.
- Checking for coordinator sessions that have idled prematurely while child workstreams or tasks are still pending or in progress.
- Resuming sessions where an agent was waiting or expected to check back in but stalled without user cancellation.

## Coordinator URL & Auth Resolution

The tool automatically resolves the Coordinator URL and Auth Token using a multi-tiered search ladder:
1. **Explicit parameter / CLI flag**: `--url <URL>` / `--token <TOKEN>` passed by the agent.
2. **Environment variables**: `TURNSTONE_CONSOLE_URL`, `TURNSTONE_COORDINATOR_URL`, `COORDINATOR_IP` (e.g. `http://${COORDINATOR_IP}:8090`), `COORDINATOR_URL`, `TURNSTONE_BASE_URL`, `TURNSTONE_API_TOKENdaily bugger`.
3. **Turnstone TOML Configs**: `$TURNSTONE_CONFIG`, `~/.config/turnstone/config.toml`, `/etc/turnstone/turnstone.toml`, `turnstone.toml`.
4. **Environment files**: `/etc/turnstone/coordinator.env`, `/etc/turnstone/postgres_admin.env`, `/opt/turnstone-coordinator/.env`, `.env`.
5. **Auto-discovery probing**: Probes responsive local/cluster endpoints (`http://127.0.0.1:8090`, `http://localhost:8090`, `http://turnstone-coordinator-nerd-projects.lan:8090`).

## Workflow

### 1. Inspect Active Coordinator Sessions

Run the inspection tool to retrieve the 5 most recent coordinator workstreams (or a custom count), their latest conversation history (default 15 messages), and their current tasks list:

```bash
# Using automatic discovery (fetches 5 most recent coordinator workstreams)
python scripts/coordinator_inspector.py inspect --pretty

# Or passing explicit coordinator URL and count (both before or after subcommand are supported)
python scripts/coordinator_inspector.py inspect --url "http://turnstone-coordinator-nerd-projects.lan:8090" --max-workstreams 5 --pretty

# Or passing global options before subcommand
python scripts/coordinator_inspector.py --url "http://turnstone-coordinator-nerd-projects.lan:8090" inspect --max-workstreams 5 --pretty
```

Available options:
- `--url <URL>` / `-u <URL>`: Override coordinator URL (supported both before and after `inspect`/`nudge`).
- `--token <TOKEN>` / `-t <TOKEN>`: Auth token / API key (supported both before and after `inspect`/`nudge`).
- `--max-workstreams <N>` (or `-n <N>` / `--count <N>`): Fetch the `N` most recent coordinator workstreams (default: 5).
- `--active-only` (or `--exclude-closed`): Filter out closed sessions and inspect only active/idle coordinators.
- `--only-open-tasks`: Show only coordinators that have pending, in-progress, or blocked tasks.
- `--limit <N>` (or `-l <N>`): Fetch the last `N` messages for deeper context per workstream (default: 15).
- `--ws-id <ws_id>`: Inspect only a specific workstream.
- `--pretty`: Pretty-print JSON output.

### 2. Evaluation Criteria for "Improperly Idled" Sessions

Inspect the JSON output returned by `inspect` and check for the following conditions:

1. **Session State is Idle or Closed**:
   - `is_idle == true` (state is `idle` or `attention` or `closed`).
2. **Open Tasks Remain**: 
   - `has_open_tasks == true` (tasks with status `pending`, `in_progress`, `blocked`, or `needs_user`).
3. **Action-Oriented Intent in Recent Messages**:
   - The coordinator's last assistant messages show unfinished workflows, such as waiting for child subagents, promising to check in later, or orchestrating multi-step tasks.
4. **No Explicit User Cancellation / Stop**:
   - The user did not send a message asking the coordinator to stop, halt, or cancel.
   - The session was not cancelled by an operator.

### 3. Send a Nudge Message to Resume Work

If a coordinator is determined to be improperly idled:

```bash
python scripts/coordinator_inspector.py nudge \
  --ws-id "<ws_id>" \
  --message "System Nudge: Child tasks and open items remain pending while the session is idle. Please check status and resume execution."
```

Or with explicit URL:
```bash
python scripts/coordinator_inspector.py nudge \
  --url "http://turnstone-coordinator-nerd-projects.lan:8090" \
  --ws-id "<ws_id>" \
  --message "System Nudge: Child tasks and open items remain pending while the session is idle. Please check status and resume execution."
```

### 4. Verify Resumption

Re-run the inspect command to verify that the coordinator has transitioned to `thinking`, `running`, or updated its task list:

```bash
python scripts/coordinator_inspector.py inspect --ws-id "<ws_id>" --pretty
```
