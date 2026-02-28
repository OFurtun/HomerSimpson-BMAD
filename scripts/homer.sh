#!/usr/bin/env bash
set -euo pipefail

# Allow nested claude -p processes when launched from within a Claude Code session
unset CLAUDECODE 2>/dev/null || true

# Homer Story Creator — Sequential Story File Generator
# Each story gets a fresh claude -p process. Zero context accumulation.
# Progress persists in PROGRESS.md (the relay baton).

# ─── Find config (next to this script's parent) ───
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${HOMER_CONFIG:-$SKILL_DIR/homer.config}"

# ─── Defaults ───
EPIC=""
STORIES_DIR="_bmad-output/implementation-artifacts"
SPRINT_STATUS="_bmad-output/implementation-artifacts/sprint-status.yaml"
EPICS_FILE="_bmad-output/planning-artifacts/epics.md"
ARCHITECTURE_DIR="_bmad-output/planning-artifacts/architecture"
RUNTIME_DIR="_homer"
HOMER_PROMPT="$SCRIPT_DIR/homer-prompt.md"
MAX_TURNS=200
MAX_CONTINUATIONS=3  # story creation is analysis, not iterative
COUNT=0              # 0 = all backlog stories
START_FROM=""
RETRY_BLOCKED=false
DRY_RUN=false
HALT_ON_BLOCK=true

# ─── Load config if it exists ───
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

# Derived paths (after config load)
PROGRESS_FILE="${PROGRESS_FILE:-$RUNTIME_DIR/PROGRESS.md}"
BLOCKERS_FILE="${BLOCKERS_FILE:-$RUNTIME_DIR/BLOCKERS.md}"

# ─── Help ───
show_help() {
  cat <<'HELP'
Homer Story Creator — Sequential Story File Generator
======================================================

Each story gets a fresh claude -p process with zero context accumulation.
Reads epics + architecture, produces ready-for-dev story files.

USAGE:
  homer.sh --epic <N> [OPTIONS]

REQUIRED:
  --epic <N>              Epic number to create stories for (e.g., 2)

OPTIONS:
  --homer-prompt <path>   Homer system prompt (default: auto-detected)
  --count <N>             Create only N stories (default: all backlog)
  --start-from <N.M>      Start from specific story (e.g., 2.3)
  --retry-blocked         Re-attempt previously blocked stories
  --no-halt-on-block      Continue past blocked stories (default: halt)
  --dry-run               Show what would execute without running
  --max-turns <N>         Max turns per story (default: 200)
  --config <path>         Path to homer.config (default: auto-detected)

EXAMPLES:
  homer.sh --epic 2                         Create all Epic 2 stories
  homer.sh --epic 2 --count 3              Create first 3 backlog stories
  homer.sh --epic 2 --start-from 2.4       Start from Story 2.4
  homer.sh --epic 2 --retry-blocked        Retry blocked stories
  homer.sh --epic 2 --dry-run              Preview without executing

STORY LIFECYCLE:
  backlog → in-progress → ready-for-dev | blocked

COMPLETION SIGNALS:
  <promise>STORY-N.M-CREATED</promise>          Story file created
  <promise>STORY-N.M-BLOCKED:reason</promise>   Story blocked

FILES:
  {runtime}/PROGRESS.md                      Relay baton between iterations
  {runtime}/BLOCKERS.md                      Failure log
  {runtime}/story-N.M-record.md              Execution records (per story)

ARCHITECTURE:
  Homer (claude -p)  → Fresh process per story, reads architecture, writes story file
  homer.sh           → Bash loop orchestrator, zero intelligence, parses completion signals
HELP
  exit 0
}

# ─── Parse arguments (override config) ───
while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help) show_help ;;
    --epic) EPIC="$2"; shift 2 ;;
    --homer-prompt) HOMER_PROMPT="$2"; shift 2 ;;
    --count) COUNT="$2"; shift 2 ;;
    --max-turns) MAX_TURNS="$2"; shift 2 ;;
    --start-from) START_FROM="$2"; shift 2 ;;
    --retry-blocked) RETRY_BLOCKED=true; shift ;;
    --no-halt-on-block) HALT_ON_BLOCK=false; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --config) CONFIG_FILE="$2"; source "$CONFIG_FILE"; shift 2 ;;
    *) echo "ERROR: Unknown option: $1"; echo "Use --help for usage."; exit 1 ;;
  esac
done

if [ -z "$EPIC" ]; then
  echo "ERROR: --epic is required"
  echo "Use --help for usage."
  exit 1
fi

# ─── Validate prerequisites ───
if [ ! -f "$HOMER_PROMPT" ]; then
  echo "ERROR: Homer prompt not found: $HOMER_PROMPT"
  exit 1
fi

if [ ! -f "$SPRINT_STATUS" ]; then
  echo "ERROR: Sprint status not found: $SPRINT_STATUS"
  echo "  Run sprint-planning first to create sprint-status.yaml."
  exit 1
fi

if [ ! -f "$EPICS_FILE" ]; then
  echo "ERROR: Epics file not found: $EPICS_FILE"
  echo "  Run the epics creation workflow first."
  exit 1
fi

if [ ! -d "$ARCHITECTURE_DIR" ]; then
  echo "ERROR: Architecture directory not found: $ARCHITECTURE_DIR"
  echo "  Run the architecture workflow first."
  exit 1
fi

# ─── Ensure runtime dir is gitignored ───
mkdir -p "$RUNTIME_DIR"
if [ ! -f ".gitignore" ] || ! grep -q "^${RUNTIME_DIR}/" ".gitignore" 2>/dev/null; then
  echo "${RUNTIME_DIR}/" >> ".gitignore"
  echo "Added ${RUNTIME_DIR}/ to .gitignore"
fi

# ─── Build static context ───
STATIC_CONTEXT="$(cat "$HOMER_PROMPT")"

# ─── Helpers ───
timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

read_progress_field() {
  local key="$1"
  local col="$2"
  awk -F'|' -v key="$key" -v col="$col" '
    $0 ~ "^\\| "key" " {
      gsub(/^ +| +$/, "", $(col+1))
      print $(col+1)
    }
  ' "$PROGRESS_FILE"
}

get_story_status() { read_progress_field "$1" 3; }
get_story_attempts() { read_progress_field "$1" 4; }
get_story_notes() { read_progress_field "$1" 5; }

update_progress_row() {
  local key="$1" new_status="$2" new_attempts="$3" new_notes="$4"
  local tmpfile
  tmpfile=$(mktemp)
  awk -F'|' -v key="$key" -v status="$new_status" -v attempts="$new_attempts" -v notes="$new_notes" '
    BEGIN { OFS="|" }
    $0 ~ "^\\| "key" " {
      slug = $3; gsub(/^ +| +$/, "", slug)
      print "| " key " | " slug " | " status " | " attempts " | " notes " |"
      next
    }
    { print }
  ' "$PROGRESS_FILE" > "$tmpfile" && mv "$tmpfile" "$PROGRESS_FILE"
}

update_story_status() {
  local key="$1" new_status="$2" new_notes="$3"
  local current_attempts
  current_attempts=$(get_story_attempts "$key")
  update_progress_row "$key" "$new_status" "$current_attempts" "$new_notes"
}

increment_attempts() {
  local key="$1" current status notes
  current=$(get_story_attempts "$key")
  status=$(get_story_status "$key")
  notes=$(get_story_notes "$key")
  update_progress_row "$key" "$status" "$((current + 1))" "$notes"
}

append_relay_notes() {
  echo "" >> "$PROGRESS_FILE"
  echo "$1" >> "$PROGRESS_FILE"
}

update_sprint_status() {
  local story_key="$1" new_status="$2"
  if [ ! -f "$SPRINT_STATUS" ]; then return; fi
  local epic_num story_num sprint_stat
  epic_num=$(echo "$story_key" | cut -d'.' -f1)
  story_num=$(echo "$story_key" | cut -d'.' -f2)
  local pattern="  ${epic_num}-${story_num}-"
  case "$new_status" in
    ready-for-dev) sprint_stat="ready-for-dev" ;;
    in-progress)   sprint_stat="in-progress" ;;
    blocked)       sprint_stat="in-progress" ;;
    *)             return ;;
  esac
  local tmpfile
  tmpfile=$(mktemp)
  awk -v pat="$pattern" -v stat="$sprint_stat" '
    index($0, pat) == 1 { match($0, /: /); print substr($0, 1, RSTART + 1) stat; next }
    { print }
  ' "$SPRINT_STATUS" > "$tmpfile" && mv "$tmpfile" "$SPRINT_STATUS"
}

update_epic_status() {
  local epic_num="$1" new_status="$2"
  if [ ! -f "$SPRINT_STATUS" ]; then return; fi
  local pattern="  epic-${epic_num}:"
  local tmpfile
  tmpfile=$(mktemp)
  awk -v pat="$pattern" -v stat="$new_status" '
    index($0, pat) == 1 { print pat " " stat; next }
    { print }
  ' "$SPRINT_STATUS" > "$tmpfile" && mv "$tmpfile" "$SPRINT_STATUS"
}

# ─── Discover backlog stories from sprint-status.yaml ───
discover_backlog_stories() {
  # Parse sprint-status.yaml for backlog entries matching epic number
  # Handles story numbers with letter suffixes (e.g., 9a, 9b)
  # Returns lines like: "2-1-rlm-engine-core-dual-adapter"
  awk -v epic="$EPIC" '
    /^  [0-9]+-[0-9]+[a-z]*-.*: backlog/ {
      gsub(/^  /, "")
      gsub(/: backlog.*$/, "")
      split($0, parts, "-")
      if (parts[1] == epic) print $0
    }
  ' "$SPRINT_STATUS"
}

mapfile -t BACKLOG_SLUGS < <(discover_backlog_stories)

if [ ${#BACKLOG_SLUGS[@]} -eq 0 ]; then
  echo "ERROR: No backlog stories found in $SPRINT_STATUS for Epic $EPIC"
  echo "  All stories may already be created (ready-for-dev or later status)."
  exit 1
fi

# ─── Build story list with key extraction ───
declare -a STORY_KEYS=()
declare -a STORY_SLUGS=()
declare -a STORY_EPIC_NUMS=()
declare -a STORY_STORY_NUMS=()

SKIP_ACTIVE=false
[ -n "$START_FROM" ] && SKIP_ACTIVE=true
COLLECTED=0

for slug in "${BACKLOG_SLUGS[@]}"; do
  epic_num=$(echo "$slug" | cut -d'-' -f1)
  story_num=$(echo "$slug" | cut -d'-' -f2)
  story_key="${epic_num}.${story_num}"

  # Handle --start-from
  if [ "$SKIP_ACTIVE" = true ]; then
    if [ "$story_key" = "$START_FROM" ]; then
      SKIP_ACTIVE=false
    else
      continue
    fi
  fi

  # Handle --count
  if [ "$COUNT" -gt 0 ] && [ "$COLLECTED" -ge "$COUNT" ]; then
    break
  fi

  STORY_KEYS+=("$story_key")
  STORY_SLUGS+=("$slug")
  STORY_EPIC_NUMS+=("$epic_num")
  STORY_STORY_NUMS+=("$story_num")
  COLLECTED=$((COLLECTED + 1))
done

if [ ${#STORY_KEYS[@]} -eq 0 ]; then
  echo "ERROR: No stories to process after applying filters."
  echo "  --start-from=${START_FROM:-none} --count=${COUNT:-all}"
  exit 1
fi

echo ""
echo "================================================================"
echo "  Homer Story Creator — Epic $EPIC"
echo "  Stories: ${#STORY_KEYS[@]}"
echo "  Max turns/story: $MAX_TURNS"
echo "  Max continuations: $MAX_CONTINUATIONS"
echo "  Halt on block: $HALT_ON_BLOCK"
echo "  Started: $(timestamp)"
echo "================================================================"
echo ""

for i in "${!STORY_KEYS[@]}"; do
  echo "  ${STORY_KEYS[$i]} — ${STORY_SLUGS[$i]}"
done
echo ""

# ─── Initialize PROGRESS.md if it doesn't exist ───
if [ ! -f "$PROGRESS_FILE" ]; then
  {
    echo "# Homer Story Creator Progress"
    echo ""
    echo "## Run Info"
    echo "- Epic: $EPIC"
    echo "- Started: $(timestamp)"
    echo "- Stories: ${#STORY_KEYS[@]}"
    echo ""
    echo "## Stories"
    echo "| Key | Slug | Status | Attempts | Notes |"
    echo "|-----|------|--------|----------|-------|"
    for j in "${!STORY_KEYS[@]}"; do
      echo "| ${STORY_KEYS[$j]} | ${STORY_SLUGS[$j]} | pending | 0 | |"
    done
    echo ""
    echo "## Relay Notes"
    echo "_Notes from completed stories for the next iteration to read._"
  } > "$PROGRESS_FILE"
  echo "  Initialized $PROGRESS_FILE"
else
  echo "  Resuming from existing $PROGRESS_FILE"
fi

# ─── Initialize blockers file ───
if [ ! -f "$BLOCKERS_FILE" ]; then
  { echo "# Homer Story Creator Blockers"; echo ""; echo "_Stories that Homer could not create._"; echo ""; } > "$BLOCKERS_FILE"
fi

# ─── Main loop ───
CREATED=0 BLOCKED=0

for i in "${!STORY_KEYS[@]}"; do
  STORY_KEY="${STORY_KEYS[$i]}"
  STORY_SLUG="${STORY_SLUGS[$i]}"
  EPIC_NUM="${STORY_EPIC_NUMS[$i]}"
  STORY_NUM="${STORY_STORY_NUMS[$i]}"
  OUTPUT_FILE="$STORIES_DIR/${STORY_SLUG}.md"

  STATUS=$(get_story_status "$STORY_KEY")

  # Skip logic
  if [ "$STATUS" = "done" ] || [ "$STATUS" = "ready-for-dev" ]; then
    echo "  >> Story $STORY_KEY — already created"
    continue
  fi
  if [ "$STATUS" = "blocked" ] && [ "$RETRY_BLOCKED" = false ]; then
    echo "  >> Story $STORY_KEY — blocked (use --retry-blocked)"
    continue
  fi

  CURRENT_ATTEMPTS=$(get_story_attempts "$STORY_KEY")

  echo "----------------------------------------------------------------"
  echo "  Story $STORY_KEY — starting (attempt $((CURRENT_ATTEMPTS + 1)))"
  echo "  Output: $OUTPUT_FILE"
  echo "  $(timestamp)"
  echo "----------------------------------------------------------------"

  if [ "$DRY_RUN" = true ]; then
    echo "  [DRY RUN] Would execute: claude -p for $STORY_SLUG"
    echo "  [DRY RUN] Output file: $OUTPUT_FILE"
    continue
  fi

  # Update epic status to in-progress if first story
  if [ "$STORY_NUM" = "1" ]; then
    update_epic_status "$EPIC_NUM" "in-progress"
  fi

  # Update story status
  update_story_status "$STORY_KEY" "in-progress" ""
  update_sprint_status "$STORY_KEY" "in-progress"
  increment_attempts "$STORY_KEY"

  # ─── Inner loop: execute with continuations on max-turns ───
  STORY_RESULT=""
  CONTINUATIONS=0

  while true; do
    # Build retry/continuation context
    RETRY_CONTEXT=""
    CURRENT_ATTEMPTS=$(get_story_attempts "$STORY_KEY")
    if [ "$CONTINUATIONS" -gt 0 ]; then
      RETRY_CONTEXT="
---
## CONTINUATION
**This is continuation #$CONTINUATIONS** (session $((CONTINUATIONS + 1)) of max $MAX_CONTINUATIONS).
The previous session hit the turn limit. Your partial story file may already exist at the output path.
**Check if the output file exists, read it, and continue from where the previous session left off.**
Do NOT redo analysis that's already captured in the file."
    elif [ "$CURRENT_ATTEMPTS" -gt 1 ]; then
      RETRY_CONTEXT="
---
## RETRY INFORMATION
**This is attempt #$CURRENT_ATTEMPTS** for this story."
      PREV_NOTES=$(get_story_notes "$STORY_KEY")
      [ -n "$PREV_NOTES" ] && RETRY_CONTEXT="$RETRY_CONTEXT
**Previous block reason:** $PREV_NOTES"
      RETRY_CONTEXT="$RETRY_CONTEXT
**Try a different approach than before.**"
    fi

    # Build per-story prompt (re-reads PROGRESS.md each iteration)
    USER_PROMPT="## Homer Context

### PROGRESS
$(cat "$PROGRESS_FILE")

### TARGET STORY
- Epic: $EPIC_NUM
- Story: $STORY_NUM
- Story Key: $STORY_SLUG
- Output File: $OUTPUT_FILE

### Web Research
enabled
$RETRY_CONTEXT"

    # ─── Execute: fresh claude -p ───
    STORY_START=$(date +%s)

    # Record file mtime before execution (if file exists)
    FILE_MTIME_BEFORE=0
    if [ -f "$OUTPUT_FILE" ]; then
      FILE_MTIME_BEFORE=$(stat -c %Y "$OUTPUT_FILE" 2>/dev/null || stat -f %m "$OUTPUT_FILE" 2>/dev/null || echo 0)
    fi

    OUTPUT=$(env -u CLAUDECODE claude -p "$USER_PROMPT" \
      --append-system-prompt "$STATIC_CONTEXT" \
      --max-turns "$MAX_TURNS" \
      --allowedTools "Read,Write,Edit,Grep,Glob,WebSearch,WebFetch,Bash" \
      --output-format text \
      2>&1) || true
    STORY_END=$(date +%s)
    STORY_DURATION=$(( STORY_END - STORY_START ))

    # ─── Parse completion signal ───
    if echo "$OUTPUT" | grep -q "<promise>STORY-${STORY_KEY}-CREATED</promise>"; then
      echo "  Story $STORY_KEY — CREATED (${STORY_DURATION}s, session $((CONTINUATIONS + 1)))"
      update_story_status "$STORY_KEY" "ready-for-dev" "created $(timestamp) (${STORY_DURATION}s)"
      update_sprint_status "$STORY_KEY" "ready-for-dev"
      CREATED=$((CREATED + 1))

      SUMMARY=$(echo "$OUTPUT" | sed -n '/^SUMMARY:/,/^<promise>/p' | head -n -1)
      [ -n "$SUMMARY" ] && append_relay_notes "### Story $STORY_KEY
$SUMMARY"

      { echo "# Story $STORY_KEY — Creation Record"; echo ""; echo "**Status:** created"; echo "**Completed:** $(timestamp)"; echo "**Duration:** ${STORY_DURATION}s"; echo "**Sessions:** $((CONTINUATIONS + 1))"; echo ""; [ -n "$SUMMARY" ] && { echo "## Summary"; echo "$SUMMARY"; echo ""; }; } > "$RUNTIME_DIR/story-${STORY_KEY}-record.md"

      STORY_RESULT="done"
      break

    elif echo "$OUTPUT" | grep -q "<promise>STORY-${STORY_KEY}-BLOCKED:"; then
      BLOCK_REASON=$(echo "$OUTPUT" | grep -o "<promise>STORY-${STORY_KEY}-BLOCKED:[^<]*</promise>" | sed "s/<promise>STORY-${STORY_KEY}-BLOCKED://;s/<\/promise>//")
      echo "  Story $STORY_KEY — BLOCKED: $BLOCK_REASON (${STORY_DURATION}s)"
      update_story_status "$STORY_KEY" "blocked" "$BLOCK_REASON"
      update_sprint_status "$STORY_KEY" "blocked"
      BLOCKED=$((BLOCKED + 1))

      # Write to blockers file
      { echo "## STORY-${STORY_KEY} — ${STORY_SLUG}"; echo "**Blocked:** $(timestamp)"; echo "**Reason:** $BLOCK_REASON"; echo ""; } >> "$BLOCKERS_FILE"

      { echo "# Story $STORY_KEY — Creation Record"; echo ""; echo "**Status:** blocked"; echo "**Blocked:** $(timestamp)"; echo "**Duration:** ${STORY_DURATION}s"; echo "**Block reason:** $BLOCK_REASON"; echo ""; } > "$RUNTIME_DIR/story-${STORY_KEY}-record.md"

      STORY_RESULT="blocked"
      break

    else
      # ─── Max turns or unexpected exit — check if progress was made ───
      echo "$OUTPUT" > "$RUNTIME_DIR/homer-debug-${STORY_KEY}.txt"

      # Check if output file was created/modified since story start
      FILE_PROGRESS=false
      if [ -f "$OUTPUT_FILE" ]; then
        FILE_MTIME_AFTER=$(stat -c %Y "$OUTPUT_FILE" 2>/dev/null || stat -f %m "$OUTPUT_FILE" 2>/dev/null || echo 0)
        if [ "$FILE_MTIME_AFTER" -gt "$FILE_MTIME_BEFORE" ]; then
          FILE_PROGRESS=true
        fi
      fi

      if [ "$FILE_PROGRESS" = true ] && [ "$CONTINUATIONS" -lt "$MAX_CONTINUATIONS" ]; then
        CONTINUATIONS=$((CONTINUATIONS + 1))
        echo "  Story $STORY_KEY — max turns, but output file modified (${STORY_DURATION}s)"
        echo "  Launching continuation $CONTINUATIONS/$MAX_CONTINUATIONS..."
        increment_attempts "$STORY_KEY"
        append_relay_notes "### Story $STORY_KEY — continuation $CONTINUATIONS
- Output file exists with partial content"
        update_story_status "$STORY_KEY" "in-progress" "continuation $CONTINUATIONS/$MAX_CONTINUATIONS"
        continue

      else
        if [ "$FILE_PROGRESS" = false ]; then
          echo "  Story $STORY_KEY — max turns, NO output file created (${STORY_DURATION}s)"
          echo "  No progress — this is a real block."
        else
          echo "  Story $STORY_KEY — exhausted $MAX_CONTINUATIONS continuations (${STORY_DURATION}s)"
          echo "  Story too complex for automated creation."
        fi
        update_story_status "$STORY_KEY" "blocked" "max-turns, no progress $(timestamp)"
        update_sprint_status "$STORY_KEY" "blocked"
        BLOCKED=$((BLOCKED + 1))

        { echo "## STORY-${STORY_KEY} — ${STORY_SLUG}"; echo "**Blocked:** $(timestamp)"; echo "**Reason:** max-turns exhausted, no completion signal"; echo ""; } >> "$BLOCKERS_FILE"

        STORY_RESULT="blocked"
        break
      fi
    fi
  done  # inner while loop (continuations)

  # Check if we need to halt the pipeline
  if [ "$STORY_RESULT" = "blocked" ] && [ "$HALT_ON_BLOCK" = true ]; then
    echo "  Halting pipeline — downstream stories may depend on this one."
    break
  fi

  echo ""
done

# ─── Final Report ───
echo ""
echo "================================================================"
echo "  Homer Story Creator — Epic $EPIC — COMPLETE"
echo "================================================================"
echo "  Created:  $CREATED"
echo "  Blocked:  $BLOCKED"
echo "  Total:    ${#STORY_KEYS[@]}"
echo ""
echo "  Finished: $(timestamp)"
echo ""
echo "  Progress: $PROGRESS_FILE"
[ -f "$BLOCKERS_FILE" ] && [ "$BLOCKED" -gt 0 ] && echo "  Blockers: $BLOCKERS_FILE"
echo "================================================================"
