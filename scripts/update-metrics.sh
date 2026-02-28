#!/usr/bin/env bash
# =============================================================================
# update-metrics.sh — Metrics dashboard orchestrator for conflictiQ
#
# Collects fresh metrics from the conflictiQ repo and updates metrics.json.
# Optionally commits and pushes to trigger GitHub Pages auto-deploy.
#
# Usage:
#   bash scripts/update-metrics.sh [--local|--ci] [/path/to/conflictiq]
#
# Modes:
#   --local  (default) Collects all 4 sections (git, claude_code, infrastructure, app).
#   --ci     Collects only git + app (CI can't resolve symlinks or ~/.claude/).
# =============================================================================
set -euo pipefail

MODE="${1:---local}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"

# Map mode to sections
case "$MODE" in
  --ci)    SECTIONS_FLAG="--sections=git,app" ;;
  --local) SECTIONS_FLAG="--sections=git,claude_code,infrastructure,app" ;;
  *)       SECTIONS_FLAG="--sections=git,claude_code,infrastructure,app" ;;
esac

# Auto-detect conflictiQ repo: explicit arg > env var > ~/conflictiq > sibling dir
if [ -n "${2:-}" ] && [ -d "${2:-}" ]; then
  CONFLICTIQ_DIR="$(cd "$2" && pwd)"
elif [ -n "${CONFLICTIQ_REPO:-}" ] && [ -d "$CONFLICTIQ_REPO" ]; then
  CONFLICTIQ_DIR="$(cd "$CONFLICTIQ_REPO" && pwd)"
elif [ -d "$HOME/conflictiq/.git" ]; then
  CONFLICTIQ_DIR="$HOME/conflictiq"
elif [ -d "$(dirname "$DEPLOY_DIR")/conflictiq/.git" ]; then
  CONFLICTIQ_DIR="$(cd "$(dirname "$DEPLOY_DIR")/conflictiq" && pwd)"
else
  echo "ERROR: Cannot find conflictiQ repo. Set CONFLICTIQ_REPO=/path/to/conflictiq or pass as arg." >&2
  exit 1
fi

echo "[metrics] Collecting from: $CONFLICTIQ_DIR (mode: $MODE, ${SECTIONS_FLAG})"

# Collect fresh metrics (only the requested sections)
FRESH_JSON=$(bash "$SCRIPT_DIR/collect-metrics.sh" "$SECTIONS_FLAG" "$CONFLICTIQ_DIR" 2>/dev/null)

if [ -f "$DEPLOY_DIR/metrics.json" ]; then
  # Section-based merge: only overwrite sections listed in collected_sections.
  # If gh CLI failed (gh_pr_ok=false), preserve PR fields from existing.
  FRESH_JSON="$FRESH_JSON" python3 - "$DEPLOY_DIR/metrics.json" <<'PY' > "$DEPLOY_DIR/metrics.json.tmp"
import json
import os
import sys

existing_path = sys.argv[1]

fresh = json.loads(os.environ["FRESH_JSON"])
with open(existing_path, "r", encoding="utf-8") as f:
    existing = json.load(f)

collected = set(fresh.get("collected_sections", []))
gh_pr_ok = fresh.get("gh_pr_ok", False)
notes = []

# For each top-level section, only overwrite if it was collected fresh
for section in ("git", "claude_code", "infrastructure", "app"):
    if section not in collected and isinstance(existing.get(section), dict):
        fresh[section] = existing[section]
        notes.append(f"Preserved {section} from previous run (not in collected_sections)")

# Field-level PR merge: if git was collected but gh failed, preserve PR fields
if "git" in collected and not gh_pr_ok:
    existing_git = existing.get("git") or {}
    if existing_git.get("prs_merged", 0) > 0:
        fresh.setdefault("git", {})
        fresh["git"]["prs_merged"] = existing_git["prs_merged"]
        if "prs_by_month" in existing_git:
            fresh["git"]["prs_by_month"] = existing_git["prs_by_month"]
        notes.append("Preserved PR metrics (gh CLI failed)")

# Strip internal fields from output — dashboard doesn't need them
fresh.pop("collected_sections", None)
fresh.pop("gh_pr_ok", None)

json.dump(fresh, sys.stdout, indent=2)
sys.stdout.write("\n")

for note in notes:
    print(note, file=sys.stderr)
PY
  mv "$DEPLOY_DIR/metrics.json.tmp" "$DEPLOY_DIR/metrics.json"
else
  # No existing file — write fresh (strip internal fields)
  echo "$FRESH_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
d.pop('collected_sections', None)
d.pop('gh_pr_ok', None)
json.dump(d, sys.stdout, indent=2)
sys.stdout.write('\n')
" > "$DEPLOY_DIR/metrics.json"
fi

# Validate JSON
if ! python3 -c "import json; json.load(open('$DEPLOY_DIR/metrics.json'))" 2>/dev/null; then
  echo "ERROR: Generated metrics.json is not valid JSON" >&2
  exit 1
fi

echo "[metrics] metrics.json updated successfully"

# Git commit and push (only if there are changes)
cd "$DEPLOY_DIR"
git pull --rebase -q origin main 2>/dev/null || true
git add metrics.json
if ! git diff --cached --quiet; then
  git commit -m "chore: update metrics $(date '+%Y-%m-%d %H:%M')"
  git push origin main || {
    # Retry once after pull if push fails (concurrent update)
    echo "[metrics] Push failed, retrying after pull..."
    git pull --rebase -q origin main
    git push origin main
  }
  echo "[metrics] Pushed to origin/main — GitHub Pages will auto-deploy"
else
  echo "[metrics] No changes detected, skipping commit"
fi
