# pr-gateway

An event-driven GitHub PR watcher daemon. It monitors pull requests via GitHub webhooks and/or polling, translates raw GitHub events into a clean signal vocabulary (`PUSHED`, `CI_GREEN`, `APPROVED`, …), and POSTs them as HMAC-signed JSON to any webhook endpoint — an AI agent, a CI orchestrator, a custom script, or anything else that accepts HTTP callbacks.

The output format is intentionally generic: standard `X-Hub-Signature-256` signing, plain JSON body. The author uses it with [Hermes Agent](https://hermes-agent.nousresearch.com), but there is no hard dependency on it.

## How it works

```
GitHub webhooks / polling
        │
        ▼
  pr-gateway.py          (daemon — two HTTP servers + poller thread)
  ├── :8645              API: register/remove/list listeners, history dashboard
  └── :8646              Webhook receiver (public, receives GitHub events)
        │
        ▼  signals: PUSHED, CI_GREEN, CI_FAILED, APPROVED, ...
  Your webhook endpoint  (any HTTP server that accepts signed JSON)
```

## Signals

| Signal | Trigger |
|--------|---------|
| `PUSHED` | New commits pushed to the PR |
| `OPENED` | PR opened or reopened |
| `MERGED` | PR merged |
| `CLOSED` | PR closed without merge |
| `DRAFT` | PR converted to draft |
| `CI_GREEN` | All CI checks passed |
| `CI_FAILED` | One or more CI checks failed |
| `CI_CANCELLED` | CI run cancelled/skipped |
| `NEW_COMMENTS` | New comments or reviews posted |
| `APPROVED` | PR approved |
| `CHANGES_REQUESTED` | Changes requested in review |
| `REVIEW_REQUESTED` | Review requested |
| `LABELED` | Label added or removed |

## Payload format

Each signal is delivered as an HMAC-signed (`X-Hub-Signature-256`) JSON POST:

```json
{
  "source":          "pr-gateway",
  "signal":          "CI_GREEN",
  "repo":            "owner/repo",
  "pr":              123,
  "branch":          "fix/my-branch",
  "worktree":        "/optional/local/path",
  "deliver_chat_id": "origin"
}
```

The `X-GitHub-Event` header is set to `pr_gateway`. Receivers that validate GitHub webhook signatures will accept the payload as-is.

`deliver_chat_id` and `worktree` are pass-through fields — pr-gateway stores whatever value was registered with the listener and echoes it back in every signal. They are ignored by receivers that don't use them.

## Source modes

- **`poll`** (default): pr-gateway polls GitHub every 30s using ETag-conditional requests (304s are free). Works for any repo, no webhook setup needed.
- **`webhook`**: GitHub sends events directly to `:8646/github/{owner}/{repo}`. Zero-latency. Supports wildcard listeners (`pr=0`) that fire for any PR on the repo.

Both modes can coexist on the same listener.

## Coalescing + serialization

GitHub fires many `check_run` events per CI run (one per job). pr-gateway coalesces identical signals within a 15-second trailing-edge window before dispatching. Additionally, only one dispatch runs per listener at a time — new signals that arrive while a handler is running are queued and flushed in a batch when it finishes.

Signal cancellation rules:
- `PUSHED` supersedes `CI_GREEN` and `CI_FAILED` (new commit invalidates previous CI state)
- `CI_GREEN` and `CI_FAILED` supersede each other (latest result wins)

## Files

| File | Purpose |
|------|---------|
| `pr-gateway.py` | Main daemon (single-file, stdlib-only) |
| `pr-gateway-ctl.sh` | start/stop/restart/status/log |
| `wait-for-pr-update.sh` | Blocking PR poller for use in shell scripts |
| `pr-gateway.service.example` | systemd unit template |

## Requirements

- Python 3.11+ (stdlib only — no pip dependencies)
- `curl` and `gh` CLI (for `wait-for-pr-update.sh` only)
- A GitHub token with `repo` scope

## Setup

### 1. GitHub token

```bash
echo "ghp_yourtoken" > ~/.secrets/gh-token
chmod 600 ~/.secrets/gh-token
```

Or set `GH_TOKEN` in the environment.

### 2. Secrets file

Create a secrets file (do **not** commit this):

```bash
# ~/.secrets/pr-gateway.env

# Shared secret for signing outbound webhook payloads
# Generate with: python3 -c "import secrets; print(secrets.token_hex(32))"
PR_GATEWAY_WEBHOOK_SECRET=your-shared-secret

# Per-repo GitHub webhook secrets (double-underscore = slash in repo name)
WEBHOOK_SECRET_apache__maven=your-github-webhook-secret-for-apache-maven
WEBHOOK_SECRET_owner__repo=your-github-webhook-secret-for-another-repo
```

### 3. Configure your webhook receiver

The outbound payload is signed with `X-Hub-Signature-256` using `PR_GATEWAY_WEBHOOK_SECRET`. Configure your receiver to validate that header with the same secret.

**Example: Hermes Agent** (`config.yaml`):
```yaml
webhooks:
  routes:
    my-route:
      secret: "your-shared-secret"   # must match PR_GATEWAY_WEBHOOK_SECRET
      deliver: origin
```

### 4. Start the daemon

```bash
# Using the control script (loads secrets from SECRETS_FILE)
SECRETS_FILE=~/.secrets/pr-gateway.env ./pr-gateway-ctl.sh start

# Or with env vars directly
PR_GATEWAY_WEBHOOK_SECRET=... PR_GATEWAY_TARGET_URL=http://localhost:8644 ./pr-gateway-ctl.sh start

# Or run directly
PR_GATEWAY_WEBHOOK_SECRET=... python3 pr-gateway.py
```

### 5. Register listeners

```bash
# Poll-based: watch apache/maven PR #1234, POST to the "my-route" endpoint
curl -X POST http://localhost:8645/watch -H 'Content-Type: application/json' -d '{
  "repo": "apache/maven",
  "pr": 1234,
  "route": "my-route",
  "signals": ["*"],
  "source": "poll",
  "branch": "fix/my-branch",
  "worktree": "/path/to/worktree",
  "deliver": "origin"
}'

# Webhook-based wildcard: fire on any PR opened in owner/repo
curl -X POST http://localhost:8645/watch -H 'Content-Type: application/json' -d '{
  "repo": "owner/repo",
  "pr": 0,
  "route": "my-route",
  "signals": ["OPENED", "PUSHED"],
  "source": "webhook"
}'
```

### 6. Set up GitHub webhooks (for webhook mode)

In the GitHub repo settings → Webhooks → Add webhook:
- **Payload URL**: `https://your-host.example.com/github/owner/repo`
- **Content type**: `application/json`
- **Secret**: the per-repo secret from `WEBHOOK_SECRET_owner__repo`
- **Events**: Pull requests, Check runs, Pull request reviews, Issue comments

## API reference

### `POST /watch` — Register a listener

```json
{
  "repo":     "owner/repo",
  "pr":       123,
  "route":    "my-route",
  "signals":  ["*"],
  "source":   "poll",
  "branch":   "fix/my-branch",
  "worktree": "/path/to/worktree",
  "deliver":  "origin"
}
```

`pr=0` + `source=webhook` = wildcard (fires for any PR on that repo).

### `DELETE /watch/{owner}/{repo}/{pr}` — Remove all listeners for a PR

### `DELETE /watch/{owner}/{repo}/{pr}/{route}` — Remove one specific listener

### `GET /watches` — List active listeners (JSON)

### `GET /history` — Recent event history ring buffer (500 entries, JSON)

### `GET /ui` — Web dashboard

### `POST /fire` — Manually inject a signal

```json
{"repo": "owner/repo", "pr": 123, "signal": "PUSHED"}
```

Useful for testing or manually re-triggering a handler.

### `POST /repo-secret` — Set a per-repo webhook secret at runtime

```json
{"repo": "owner/repo", "secret": "your-secret"}
```

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PR_GATEWAY_WEBHOOK_SECRET` | *(required)* | Shared secret for signing outbound payloads (`X-Hub-Signature-256`) |
| `PR_GATEWAY_TARGET_URL` | `http://localhost:8644` | Base URL of the webhook receiver |
| `PR_GATEWAY_PORT` | `8645` | Internal API port |
| `PR_GATEWAY_GH_PORT` | `8646` | Public GitHub webhook receiver port |
| `PR_GATEWAY_POLL_INTERVAL` | `30` | GitHub poll interval in seconds |
| `GH_TOKEN` | *(from `~/.secrets/gh-token`)* | GitHub API token |
| `WEBHOOK_SECRET_owner__repo` | *(falls back to `PR_GATEWAY_WEBHOOK_SECRET`)* | Per-repo GitHub webhook secret |

## systemd

Copy and adapt `pr-gateway.service.example`:

```bash
cp pr-gateway.service.example ~/.config/systemd/user/pr-gateway.service
# Edit paths and secrets
systemctl --user daemon-reload
systemctl --user enable --now pr-gateway
```

## License

MIT
# ETag test Wed Sep  9 12:12:07 UTC 2026
# Another change Wed Sep  9 12:12:49 UTC 2026
