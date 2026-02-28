#!/usr/bin/env bash
# =============================================================================
# collect-metrics.sh — conflictiQ project metrics collector
#
# Collects git stats, Claude Code session data, infrastructure counts,
# and application metrics (generic LOC by language). Outputs JSON to stdout.
#
# Usage:
#   bash scripts/collect-metrics.sh [--sections=git,app,...] [/path/to/conflictiq] [start] [end]
#   bash scripts/collect-metrics.sh --sections=git,app /path/to/conflictiq
#   bash scripts/collect-metrics.sh /path/to/conflictiq 2026-02-01
#   bash scripts/collect-metrics.sh                                       # all sections
#
# Sections: git, claude_code, infrastructure, app (default: all)
#
# Works on both macOS (local) and Linux (GitHub Actions).
# =============================================================================
set -uo pipefail
# NOTE: We do NOT use `set -e` because many counting commands (grep -c, find on
# missing dirs) legitimately return non-zero. Each command handles errors locally.

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse --sections flag
SECTIONS_CSV="git,claude_code,infrastructure,app"
if [[ "${1:-}" == --sections=* ]]; then
  SECTIONS_CSV="${1#--sections=}"
  shift
fi

# Build lookup for should_collect
declare -A COLLECT_SECTIONS
IFS=',' read -ra _SECTS <<< "$SECTIONS_CSV"
for _s in "${_SECTS[@]}"; do
  COLLECT_SECTIONS["$_s"]=1
done

should_collect() {
  [[ -n "${COLLECT_SECTIONS[$1]+x}" ]]
}

# First arg: repo path (if it's a directory), otherwise fall back to parent of script dir
if [ -n "${1:-}" ] && [ -d "${1:-}" ]; then
  REPO_ROOT="$(cd "$1" && pwd)"
  shift
else
  REPO_ROOT="$(dirname "$SCRIPT_DIR")"
fi

START_DATE="${1:-2026-02-01}"
END_DATE="${2:-$(date '+%Y-%m-%d')}"

# Claude Code session data directory — auto-detect from repo path
# Converts /Users/foo/conflictiq → -Users-foo-conflictiq for Claude's directory naming
CLAUDE_SESSION_DIR="$HOME/.claude/projects/$(echo "$REPO_ROOT" | sed 's|/|-|g')"

# ---------------------------------------------------------------------------
# Portable helpers
# ---------------------------------------------------------------------------
days_between() {
  local start="$1" end="$2"
  local s_epoch=0 end_epoch=0
  if date --version >/dev/null 2>&1; then
    # GNU date (Linux)
    s_epoch=$(date -d "$start" +%s 2>/dev/null || echo 0)
    end_epoch=$(date -d "$end" +%s 2>/dev/null || echo 0)
  else
    # BSD date (macOS)
    s_epoch=$(date -jf "%Y-%m-%d" "$start" +%s 2>/dev/null || echo 0)
    end_epoch=$(date -jf "%Y-%m-%d" "$end" +%s 2>/dev/null || echo 0)
  fi
  echo $(( (end_epoch - s_epoch) / 86400 ))
}

# Safe count: find files and count lines matching a pattern
safe_count_matches() {
  local pattern="$1"
  shift
  local total=0
  for f in "$@"; do
    if [ -f "$f" ]; then
      local c
      c=$(grep -c "$pattern" "$f" 2>/dev/null || true)
      total=$((total + c))
    fi
  done
  echo "$total"
}

# ---------------------------------------------------------------------------
# 1. Git Metrics
# ---------------------------------------------------------------------------
cd "$REPO_ROOT"

TOTAL_COMMITS=0
COMMITS_BY_MONTH="{}"
CLAUDE_COAUTHORED=0
LINES_INSERTED=0
LINES_DELETED=0
ACTIVE_DAYS=0
CALENDAR_SPAN=0
GH_PR_OK=false
PRS_MERGED=0
PRS_BY_MONTH="{}"

if should_collect git; then
  # Total commits in date range
  TOTAL_COMMITS=$(git log --oneline --after="${START_DATE}T00:00:00" --before="${END_DATE}T23:59:59" 2>/dev/null | wc -l | tr -d ' ')

  # Commits by month — output as JSON object
  COMMITS_BY_MONTH=$(git log --format="%ad" --date=format:"%Y-%m" --after="${START_DATE}T00:00:00" --before="${END_DATE}T23:59:59" 2>/dev/null \
    | sort | uniq -c | sort -k2 \
    | awk 'BEGIN{first=1; printf "{"} {if(!first) printf ","; printf "\"%s\":%d", $2, $1; first=0} END{printf "}"}')
  [ -z "$COMMITS_BY_MONTH" ] && COMMITS_BY_MONTH="{}"

  # Claude co-authored commits (use multiple --grep flags with OR logic)
  CLAUDE_COAUTHORED=$(git log --oneline \
    --after="${START_DATE}T00:00:00" --before="${END_DATE}T23:59:59" \
    --grep="Co-Authored-By:" --grep="Co-authored-by:" --grep="noreply@anthropic" \
    2>/dev/null | wc -l | tr -d ' ')

  # Lines inserted/deleted (from diffstat)
  DIFF_STATS=$(git log --after="${START_DATE}T00:00:00" --before="${END_DATE}T23:59:59" --numstat --format="" 2>/dev/null \
    | awk 'BEGIN{ins=0;del=0} $1~/^[0-9]+$/{ins+=$1;del+=$2} END{printf "%d %d", ins, del}')
  LINES_INSERTED=$(echo "$DIFF_STATS" | awk '{print $1}')
  LINES_DELETED=$(echo "$DIFF_STATS" | awk '{print $2}')

  # Active days (unique commit dates)
  ACTIVE_DAYS=$(git log --format="%ad" --date=format:"%Y-%m-%d" --after="${START_DATE}T00:00:00" --before="${END_DATE}T23:59:59" 2>/dev/null \
    | sort -u | wc -l | tr -d ' ')

  # Calendar span
  CALENDAR_SPAN=$(days_between "$START_DATE" "$END_DATE")

  # PRs merged (requires gh CLI) — track whether gh succeeded
  if command -v gh >/dev/null 2>&1; then
    _pr_json=$(gh pr list --state merged --limit 500 --json mergedAt 2>/dev/null) && GH_PR_OK=true || true
    if $GH_PR_OK && [ -n "$_pr_json" ]; then
      PRS_MERGED=$(echo "$_pr_json" \
        | jq "[.[] | select(.mergedAt >= \"${START_DATE}T00:00:00Z\" and .mergedAt <= \"${END_DATE}T23:59:59Z\")] | length" 2>/dev/null || echo 0)
      PRS_BY_MONTH=$(echo "$_pr_json" \
        | jq "[.[] | select(.mergedAt >= \"${START_DATE}T00:00:00Z\" and .mergedAt <= \"${END_DATE}T23:59:59Z\") | .mergedAt[:7]] | group_by(.) | map({(.[0]): length}) | add // {}" 2>/dev/null || echo "{}")
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 2. Claude Code Session Metrics
# ---------------------------------------------------------------------------
SESSIONS=0
SESSION_DATA_MB=0
AGENT_SPAWNS=0
SKILL_INVOCATIONS=0
HUMAN_MESSAGES=0
AI_MESSAGES=0
TOOL_USES=0

if should_collect claude_code && [ -d "$CLAUDE_SESSION_DIR" ]; then
  # Count session JSONL files
  SESSIONS=$(find "$CLAUDE_SESSION_DIR" -maxdepth 1 -name "*.jsonl" -type f 2>/dev/null | wc -l | tr -d ' ')

  # Total size in MB
  SESSION_DATA_KB=$(du -sk "$CLAUDE_SESSION_DIR" 2>/dev/null | awk '{print $1}')
  SESSION_DATA_MB=$(echo "scale=1; ${SESSION_DATA_KB:-0} / 1024" | bc 2>/dev/null || echo 0)

  # Parse JSONL files for message counts
  if [ "$SESSIONS" -gt 0 ]; then
    COUNTS=$(find "$CLAUDE_SESSION_DIR" -maxdepth 1 -name "*.jsonl" -type f 2>/dev/null \
      | xargs awk '
        /"type":"user"/ || /"type": "user"/ { human++ }
        /"type":"assistant"/ || /"type": "assistant"/ { ai++ }
        /"type":"tool_use"/ || /"type": "tool_use"/ || /"type":"tool_result"/ || /"type": "tool_result"/ { tools++ }
        /subagent/ || /"agent_spawn"/ || /TaskStart/ { agents++ }
        /Skill/ || /skill_invocation/ || /\"skill\"/ { skills++ }
        END { printf "%d %d %d %d %d", human+0, ai+0, tools+0, agents+0, skills+0 }
      ' 2>/dev/null || echo "0 0 0 0 0")

    HUMAN_MESSAGES=$(echo "$COUNTS" | awk '{print $1}')
    AI_MESSAGES=$(echo "$COUNTS" | awk '{print $2}')
    TOOL_USES=$(echo "$COUNTS" | awk '{print $3}')
    AGENT_SPAWNS=$(echo "$COUNTS" | awk '{print $4}')
    SKILL_INVOCATIONS=$(echo "$COUNTS" | awk '{print $5}')
  fi
fi

# ---------------------------------------------------------------------------
# 3. Infrastructure Metrics (.claude/ directory)
# ---------------------------------------------------------------------------
AGENTS_COUNT=0
SKILLS_COUNT=0
HOOKS_COUNT=0
PLUGINS_COUNT=0
PLANS_COUNT=0
WORKFLOWS_COUNT=0

if should_collect infrastructure; then
  CLAUDE_DIR="$REPO_ROOT/.claude"

  if [ -d "$CLAUDE_DIR" ]; then
    # Agents — count real .md files + symlinked .md files (symlinks are broken in CI)
    if [ -d "$CLAUDE_DIR/agents" ]; then
      real_agents=$(find "$CLAUDE_DIR/agents" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
      link_agents=$(find "$CLAUDE_DIR/agents" -maxdepth 1 -name "*.md" -type l 2>/dev/null | wc -l | tr -d ' ')
      AGENTS_COUNT=$((real_agents + link_agents))
    fi

    # Skills — real SKILL.md in dirs + symlinked skill entries (each symlink = 1 skill)
    if [ -d "$CLAUDE_DIR/skills" ]; then
      real_skills=$(find "$CLAUDE_DIR/skills" -name "SKILL.md" -type f 2>/dev/null | wc -l | tr -d ' ')
      link_skills=$(find "$CLAUDE_DIR/skills" -maxdepth 1 -type l 2>/dev/null | wc -l | tr -d ' ')
      SKILLS_COUNT=$((real_skills + link_skills))
    fi

    # Hooks — real files + symlinked files
    if [ -d "$CLAUDE_DIR/hooks" ]; then
      real_hooks=$(find "$CLAUDE_DIR/hooks" -type f 2>/dev/null | wc -l | tr -d ' ')
      link_hooks=$(find "$CLAUDE_DIR/hooks" -maxdepth 1 -type l 2>/dev/null | wc -l | tr -d ' ')
      HOOKS_COUNT=$((real_hooks + link_hooks))
    fi

    # Plugins (from settings.json)
    if [ -f "$CLAUDE_DIR/settings.json" ]; then
      PLUGINS_COUNT=$(python3 -c "
import json, sys
try:
    with open('$CLAUDE_DIR/settings.json') as f:
        data = json.load(f)
    plugins = data.get('enabledPlugins', {})
    print(sum(1 for v in plugins.values() if v))
except Exception:
    print(0)
" 2>/dev/null || echo 0)
    fi

    # Plans
    if [ -d "$CLAUDE_DIR/plans" ]; then
      PLANS_COUNT=$(find "$CLAUDE_DIR/plans" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
    fi
  fi

  # GitHub Actions workflows
  if [ -d "$REPO_ROOT/.github/workflows" ]; then
    WORKFLOWS_COUNT=$(find "$REPO_ROOT/.github/workflows" \( -name "*.yml" -o -name "*.yaml" \) -type f 2>/dev/null | wc -l | tr -d ' ')
  fi
fi

# ---------------------------------------------------------------------------
# 4. Application Metrics — Generic LOC by Language
# ---------------------------------------------------------------------------
PYTHON_LOC=0
TYPESCRIPT_LOC=0
JAVASCRIPT_LOC=0
PYTHON_TESTS=0
JS_TESTS=0

if should_collect app; then
  # Python LOC (all *.py files, excluding venv/node_modules/__pycache__)
  PYTHON_LOC=$(find "$REPO_ROOT" \
    -name "*.py" \
    -not -path "*/venv/*" -not -path "*/.venv/*" \
    -not -path "*/node_modules/*" -not -path "*/__pycache__/*" \
    2>/dev/null | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}' || echo 0)
  # If only one file, tail -1 IS that file (no "total" line)
  if [ "$PYTHON_LOC" -eq 0 ] 2>/dev/null; then
    PYTHON_LOC=$(find "$REPO_ROOT" \
      -name "*.py" \
      -not -path "*/venv/*" -not -path "*/.venv/*" \
      -not -path "*/node_modules/*" -not -path "*/__pycache__/*" \
      2>/dev/null | xargs wc -l 2>/dev/null | awk '{s+=$1} END{print s+0}' || echo 0)
  fi

  # TypeScript LOC (all *.ts + *.tsx, excluding node_modules)
  TYPESCRIPT_LOC=$(find "$REPO_ROOT" \
    \( -name "*.ts" -o -name "*.tsx" \) \
    -not -path "*/node_modules/*" \
    2>/dev/null | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}' || echo 0)
  if [ "$TYPESCRIPT_LOC" -eq 0 ] 2>/dev/null; then
    TYPESCRIPT_LOC=$(find "$REPO_ROOT" \
      \( -name "*.ts" -o -name "*.tsx" \) \
      -not -path "*/node_modules/*" \
      2>/dev/null | xargs wc -l 2>/dev/null | awk '{s+=$1} END{print s+0}' || echo 0)
  fi

  # JavaScript LOC (all *.js + *.jsx, excluding node_modules)
  JAVASCRIPT_LOC=$(find "$REPO_ROOT" \
    \( -name "*.js" -o -name "*.jsx" \) \
    -not -path "*/node_modules/*" \
    2>/dev/null | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}' || echo 0)
  if [ "$JAVASCRIPT_LOC" -eq 0 ] 2>/dev/null; then
    JAVASCRIPT_LOC=$(find "$REPO_ROOT" \
      \( -name "*.js" -o -name "*.jsx" \) \
      -not -path "*/node_modules/*" \
      2>/dev/null | xargs wc -l 2>/dev/null | awk '{s+=$1} END{print s+0}' || echo 0)
  fi

  # Python tests — count test functions in test_*.py files
  PYTHON_TEST_FILES=()
  while IFS= read -r f; do
    PYTHON_TEST_FILES+=("$f")
  done < <(find "$REPO_ROOT" -name "test_*.py" -type f \
    -not -path "*/venv/*" -not -path "*/.venv/*" -not -path "*/node_modules/*" \
    2>/dev/null)
  PYTHON_TESTS=$(safe_count_matches "def test_" "${PYTHON_TEST_FILES[@]}")

  # JS/TS tests — count it() and test() calls in *.test.{ts,tsx,js,jsx}
  JS_TESTS=0
  while IFS= read -r f; do
    c=$(grep -cE "(^|[[:space:]])(it|test)\(" "$f" 2>/dev/null || true)
    JS_TESTS=$((JS_TESTS + c))
  done < <(find "$REPO_ROOT" \
    \( -name "*.test.ts" -o -name "*.test.tsx" -o -name "*.test.js" -o -name "*.test.jsx" \) \
    -type f -not -path "*/node_modules/*" \
    2>/dev/null)
fi

# ---------------------------------------------------------------------------
# 5. Build collected_sections list
# ---------------------------------------------------------------------------
_collected=()
for _s in git claude_code infrastructure app; do
  should_collect "$_s" && _collected+=("\"$_s\"")
done
COLLECTED_JSON=$(IFS=','; echo "[${_collected[*]}]")

# ---------------------------------------------------------------------------
# 6. Output JSON
# ---------------------------------------------------------------------------
cat <<EOF
{
  "collected_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "collected_sections": $COLLECTED_JSON,
  "gh_pr_ok": $GH_PR_OK,
  "period": {
    "start": "$START_DATE",
    "end": "$END_DATE"
  },
  "git": {
    "total_commits": $TOTAL_COMMITS,
    "commits_by_month": $COMMITS_BY_MONTH,
    "prs_merged": $PRS_MERGED,
    "prs_by_month": $PRS_BY_MONTH,
    "lines_inserted": $LINES_INSERTED,
    "lines_deleted": $LINES_DELETED,
    "net_lines": $(( LINES_INSERTED - LINES_DELETED )),
    "active_days": $ACTIVE_DAYS,
    "calendar_span": $CALENDAR_SPAN,
    "claude_coauthored": $CLAUDE_COAUTHORED
  },
  "claude_code": {
    "sessions": $SESSIONS,
    "session_data_mb": $SESSION_DATA_MB,
    "agent_spawns": $AGENT_SPAWNS,
    "skill_invocations": $SKILL_INVOCATIONS,
    "human_messages": $HUMAN_MESSAGES,
    "ai_messages": $AI_MESSAGES,
    "tool_uses": $TOOL_USES
  },
  "infrastructure": {
    "agents": $AGENTS_COUNT,
    "skills": $SKILLS_COUNT,
    "hooks": $HOOKS_COUNT,
    "plugins": $PLUGINS_COUNT,
    "plans": $PLANS_COUNT,
    "workflows": $WORKFLOWS_COUNT
  },
  "app": {
    "python_loc": $PYTHON_LOC,
    "typescript_loc": $TYPESCRIPT_LOC,
    "javascript_loc": $JAVASCRIPT_LOC,
    "python_tests": $PYTHON_TESTS,
    "js_tests": $JS_TESTS
  }
}
EOF
