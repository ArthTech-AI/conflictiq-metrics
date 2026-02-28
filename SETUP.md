# Metrics Dashboard Setup

Live at: https://arthtech-ai.github.io/conflictiq-metrics/

The dashboard auto-updates from `metrics.json`. There are three update paths:
1. **GitHub Action** — runs daily at 6am UTC (auto)
2. **Post-commit hook** — updates after every git commit in `~/conflictiq` (auto)
3. **Cron job** — runs nightly at 10pm local time (auto)
4. **Manual** — run the script anytime

---

## Prerequisites

- **Homebrew** — required for bash 5 and gh CLI: https://brew.sh
- **bash 5+** — macOS ships with bash 3.2 which is too old: `brew install bash`
- **gh CLI** — needed for PR metrics: `brew install gh && gh auth login`
- **jq** — usually pre-installed on macOS, otherwise: `brew install jq`

## One-Time Setup (Each Founder)

### 1. Clone the metrics repo

```bash
cd ~ && git clone git@github.com:ArthTech-AI/conflictiq-metrics.git
```

### 2. Verify the collection script works

```bash
cd ~/conflictiq-metrics
bash scripts/update-metrics.sh --local ~/conflictiq
```

You should see:
```
[metrics] Collecting from: /Users/<you>/conflictiq (mode: --local)
[metrics] metrics.json updated successfully
[metrics] Pushed to origin/main — GitHub Pages will auto-deploy
```

### 3. Install the post-commit hook

This automatically updates the dashboard after every commit in `~/conflictiq`:

```bash
cat > ~/conflictiq/.git/hooks/post-commit << 'HOOK'
#!/usr/bin/env bash
# Auto-update metrics dashboard after every commit
# Runs in background so it doesn't slow down your workflow
METRICS_REPO="$HOME/conflictiq-metrics"
if [ -d "$METRICS_REPO" ]; then
  (cd "$METRICS_REPO" && git pull -q origin main 2>/dev/null && bash scripts/update-metrics.sh --local "$HOME/conflictiq" 2>/dev/null && echo "[metrics] Dashboard updated") &
fi
HOOK
chmod +x ~/conflictiq/.git/hooks/post-commit
```

### 4. Install the nightly cron job

The `PATH` line is required — cron runs with a minimal environment that can't find Homebrew tools (`bash 5`, `gh`, `git`) without it.

```bash
(crontab -l 2>/dev/null | grep -v conflictiq-metrics; printf '%s\n' 'PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin' '0 22 * * * cd ~/conflictiq-metrics && git pull -q origin main 2>/dev/null && bash scripts/update-metrics.sh --local ~/conflictiq >> /tmp/conflictiq-metrics-cron.log 2>&1') | crontab -
```

Verify it was added:
```bash
crontab -l | grep conflictiq
```

---

## Manual Update (Anytime)

```bash
cd ~/conflictiq-metrics && bash scripts/update-metrics.sh --local ~/conflictiq
```

---

## How It Works

- `scripts/collect-metrics.sh` scans the conflictiQ repo (git stats, code counts, Claude Code sessions) and outputs JSON
- `scripts/update-metrics.sh` runs the collector, writes `metrics.json`, commits, and pushes
- GitHub Pages auto-deploys on push to `main`
- `index.html` fetches `metrics.json` at runtime and updates all stats + charts dynamically
- Metrics updated within the last hour show a cyan "LIVE" pulse animation

## What Gets Collected

| Section | Source | Needs Local Machine? |
|---------|--------|---------------------|
| Git stats (commits, PRs, lines) | `git log` in conflictiQ repo | No (CI can do this) |
| Claude Code (sessions, tool uses) | `~/.claude/projects/` | **Yes** |
| Infrastructure (agents, skills) | `.claude/` directory in repo | No |
| App stats (LOC by language, tests) | Source files in repo | No |

The GitHub Action runs in `--ci` mode which collects everything **except** Claude Code data (preserves the last local values). Only local runs (`--local` mode) can refresh Claude Code stats.

---

## Troubleshooting

**"Cannot find conflictiQ repo"** — Make sure `~/conflictiq` exists or pass the path explicitly:
```bash
bash scripts/update-metrics.sh --local /path/to/conflictiq
```

**Push conflicts** — The script auto-retries with `git pull --rebase`. If it still fails:
```bash
cd ~/conflictiq-metrics && git pull --rebase origin main && git push
```

**Cron not running** — Check logs:
```bash
cat /tmp/conflictiq-metrics-cron.log
```

**JSONDecodeError in cron log** — Cron can't find Homebrew's bash 5. Make sure your crontab has the `PATH` line:
```bash
crontab -l | head -1
# Should show: PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
```
If missing, re-run step 4 above.
