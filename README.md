# hermes-pr-gateway

An event-driven GitHub PR watcher daemon that bridges GitHub activity to [Hermes Agent](https://hermes-agent.nousresearch.com) webhook routes.

It monitors pull requests via GitHub webhooks and/or polling, detects meaningful state changes, and fires signals to Hermes automation routes (e.g. `babysit-pr`, `review-loop`).

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
  Hermes webhook route   (http://localhost:8644/webhooks/<route>)
        │
        ▼
  Hermes agent           (babysit-pr, review-loop, ...)
```

### Signals

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

### Source modes

- **`poll`** (default): pr-gateway polls GitHub every 30s using ETag-conditional requests (304s are free). Good for repos where you can't install webhooks, or as a fallback.
- **`webhook`**: GitHub sends events directly to `:8646/github/{owner}/{repo}`. Zero-latency, no polling needed. Supports wildcard listeners (`pr=0`) for repo-level automation that fires on any PR.

Both modes can coexist — a PR can have poll and webhook listeners simultaneously.

### Coalescing + serialization

GitHub fires many `check_run` events per CI run (one per job). pr-gateway coalesces identical signals within a 15-second trailing-edge window before dispatching. Additionally, only one agent invocation runs per listener at a time — new signals that arrive while an agent is running are queued and dispatched in a batch when it finishes.

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
- A running [Hermes Agent](https://hermes-agent.nousresearch.com) instance with the webhook gateway enabled

## Setup

### 1. GitHub token

```bash
echo "ghp_yourtoken" > ~/.secrets/gh-token
chmod 600 ~/.secrets/gh-token
```

Or set `GH_TOKEN` in the environment / secrets file.

### 2. Secrets file

Create a secrets file (do **not** commit this):

```bash
# ~/.secrets/pr-gateway-webhook-secrets.env

# Hermes webhook shared secret (generate with: python3 -c "import secrets; print(secrets.token_hex(32))")
PR_GATEWAY_HERMES_SECRET=your-hermes-webhook-secret

# Per-repo GitHub webhook secrets (double-underscore = slash in repo name)
WEBHOOK_SECRET_apache__maven=your-github-webhook-secret-for-apache-maven
WEBHOOK_SECRET_maveniverse__scalpel=your-github-webhook-secret-for-scalpel
```

### 3. Configure Hermes

In your Hermes `config.yaml`, define the webhook routes:

```yaml
webhooks:
  routes:
    babysit-pr:
      secret: "your-hermes-webhook-secret"   # must match PR_GATEWAY_HERMES_SECRET
      deliver: origin
    review-loop:
      secret: "your-hermes-webhook-secret"
      deliver: origin
```

### 4. Start the daemon

```bash
# Using the control script
PR_GATEWAY_HERMES_SECRET=... ./pr-gateway-ctl.sh start

# Or with a secrets file
SECRETS_FILE=~/.secrets/pr-gateway-webhook-secrets.env ./pr-gateway-ctl.sh start

# Or directly
PR_GATEWAY_HERMES_SECRET=... python3 pr-gateway.py
```

### 5. Register listeners

```bash
# Poll-based listener: watch apache/maven PR #1234, call the babysit-pr route
curl -X POST http://localhost:8645/watch -H 'Content-Type: application/json' -d '{
  "repo": "apache/maven",
  "pr": 1234,
  "route": "babysit-pr",
  "signals": ["*"],
  "source": "poll",
  "branch": "fix/my-branch",
  "worktree": "/path/to/worktree",
  "deliver": "origin"
}'

# Webhook-based wildcard: fire on any new PR opened in maveniverse/scalpel
curl -X POST http://localhost:8645/watch -H 'Content-Type: application/json' -d '{
  "repo": "maveniverse/scalpel",
  "pr": 0,
  "route": "review-loop",
  "signals": ["OPENED", "PUSHED"],
  "source": "webhook"
}'
```

### 6. Set up GitHub webhooks (for webhook mode)

In the GitHub repo settings → Webhooks → Add webhook:
- **Payload URL**: `https://your-host.example.com/github/owner/repo`
- **Content type**: `application/json`
- **Secret**: the per-repo secret you set in `WEBHOOK_SECRET_owner__repo`
- **Events**: select the events you want (at minimum: Pull requests, Check runs, Pull request reviews, Issue comments)

## API reference

### `POST /watch` — Register a listener

```json
{
  "repo":     "owner/repo",
  "pr":       123,
  "route":    "babysit-pr",
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

Useful for testing or manually re-triggering an agent.

### `POST /repo-secret` — Set a per-repo webhook secret at runtime

```json
{"repo": "owner/repo", "secret": "your-secret"}
```

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PR_GATEWAY_HERMES_SECRET` | *(required)* | Shared secret for Hermes webhook HMAC |
| `PR_GATEWAY_PORT` | `8645` | Internal API port |
| `PR_GATEWAY_GH_PORT` | `8646` | Public GitHub webhook receiver port |
| `PR_GATEWAY_HERMES_URL` | `http://localhost:8644` | Hermes gateway base URL |
| `PR_GATEWAY_POLL_INTERVAL` | `30` | GitHub poll interval in seconds |
| `GH_TOKEN` | *(from `~/.secrets/gh-token`)* | GitHub API token |
| `WEBHOOK_SECRET_owner__repo` | *(falls back to `HERMES_SECRET`)* | Per-repo GitHub webhook secret |

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
