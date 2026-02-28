#!/usr/bin/env bash
set -euo pipefail

# HomerSimpson-BMAD Installer
# Installs Homer into a target project's .claude/skills/homer/

INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "================================================================"
echo "  HomerSimpson-BMAD Installer"
echo "================================================================"
echo ""

# ─── Step 1: Pick target project ───
echo "-- Target Project -----------------------------------------"
echo ""

if [ -n "${1:-}" ]; then
  TARGET_DIR="$1"
else
  read -rp "  Project directory to install into: " TARGET_DIR
fi

# Expand ~ and resolve path
TARGET_DIR="${TARGET_DIR/#\~/$HOME}"
TARGET_DIR="$(cd "$TARGET_DIR" 2>/dev/null && pwd)" || {
  echo "ERROR: Directory does not exist: $TARGET_DIR"
  exit 1
}

if [ ! -d "$TARGET_DIR/.git" ]; then
  echo "WARNING: $TARGET_DIR is not a git repository."
  read -rp "  Continue anyway? [y/N]: " CONTINUE
  if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
  fi
fi

echo "  Installing into: $TARGET_DIR"
echo ""

# ─── Step 2: Detect BMAD ───
BMAD_DETECTED=false
if [ -d "$TARGET_DIR/_bmad-output/implementation-artifacts" ] || [ -d "$TARGET_DIR/_bmad-output/planning-artifacts" ]; then
  BMAD_DETECTED=true
  echo "  Detected: BMAD project structure"
elif [ -d "$TARGET_DIR/_bmad" ] || [ -d "$TARGET_DIR/_bmad-project" ]; then
  BMAD_DETECTED=true
  echo "  Detected: BMAD installation (no output yet)"
else
  echo "  No BMAD installation detected -- using generic defaults"
fi
echo ""

# ─── Helper ───
ask() {
  local prompt="$1"
  local default="$2"
  local result
  read -rp "  $prompt [$default]: " result
  echo "${result:-$default}"
}

# ─── Step 3: Configure paths ───
echo "-- Epics File ------------------------------------------------"
echo "  Markdown file with epic definitions and story requirements."
echo ""
if [ "$BMAD_DETECTED" = true ]; then
  EPICS_FILE=$(ask "Epics file (relative to project root)" "_bmad-output/planning-artifacts/epics.md")
else
  EPICS_FILE=$(ask "Epics file (relative to project root)" "docs/epics.md")
fi
echo ""

echo "-- Architecture Docs -----------------------------------------"
echo "  Directory containing architecture documentation."
echo "  Homer reads these to extract canonical schemas, patterns, and constraints."
echo ""
if [ "$BMAD_DETECTED" = true ]; then
  ARCHITECTURE_DIR=$(ask "Architecture docs directory" "_bmad-output/planning-artifacts/architecture")
else
  ARCHITECTURE_DIR=$(ask "Architecture docs directory (or 'none')" "none")
fi
echo ""

echo "-- Sprint Status ─────────────────────────────────────────────"
echo "  A YAML file tracking story statuses. Homer discovers backlog stories from this."
echo ""
if [ "$BMAD_DETECTED" = true ]; then
  SPRINT_STATUS=$(ask "Sprint status file" "_bmad-output/implementation-artifacts/sprint-status.yaml")
else
  SPRINT_STATUS=$(ask "Sprint status file" "sprint-status.yaml")
fi
echo ""

echo "-- Story Output Directory ------------------------------------"
echo "  Where Homer writes the generated story files."
echo ""
if [ "$BMAD_DETECTED" = true ]; then
  STORIES_DIR=$(ask "Story output directory" "_bmad-output/implementation-artifacts")
else
  STORIES_DIR=$(ask "Story output directory" "stories")
fi
echo ""

echo "-- Runtime Directory -----------------------------------------"
echo "  Where Homer stores progress, blockers, and creation records."
echo "  Auto-added to .gitignore."
echo ""
RUNTIME_DIR=$(ask "Runtime directory" "_homer")
echo ""

echo "-- Tuning ----------------------------------------------------"
echo ""
MAX_TURNS=$(ask "Max turns per story (claude -p)" "200")
echo ""

# ─── Step 4: Install files ───
SKILL_DIR="$TARGET_DIR/.claude/skills/homer"
mkdir -p "$SKILL_DIR/scripts"

echo "-- Installing ------------------------------------------------"

# Copy scripts and prompts
cp "$INSTALLER_DIR/scripts/homer.sh" "$SKILL_DIR/scripts/homer.sh"
cp "$INSTALLER_DIR/prompts/homer-prompt.md" "$SKILL_DIR/scripts/homer-prompt.md"
cp "$INSTALLER_DIR/skill/SKILL.md" "$SKILL_DIR/SKILL.md"
chmod +x "$SKILL_DIR/scripts/homer.sh"

echo "  Copied: SKILL.md"
echo "  Copied: scripts/homer.sh"
echo "  Copied: scripts/homer-prompt.md"

# ─── Step 5: Write config into the skill directory ───
cat > "$SKILL_DIR/homer.config" <<CONF
# HomerSimpson-BMAD Configuration
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Project: $(basename "$TARGET_DIR")

# Source artifacts (read-only)
EPICS_FILE="$EPICS_FILE"
ARCHITECTURE_DIR="$ARCHITECTURE_DIR"
SPRINT_STATUS="$SPRINT_STATUS"

# Output
STORIES_DIR="$STORIES_DIR"

# Runtime
RUNTIME_DIR="$RUNTIME_DIR"

# Tuning
MAX_TURNS=$MAX_TURNS
CONF

echo "  Written: homer.config"

# ─── Step 6: Update SKILL.md paths from config ───
# The generic SKILL.md is fine — homer.sh reads from homer.config

echo ""

# ─── Step 7: Ensure runtime dir gitignored ───
GITIGNORE="$TARGET_DIR/.gitignore"
if [ ! -f "$GITIGNORE" ] || ! grep -q "^${RUNTIME_DIR}/" "$GITIGNORE" 2>/dev/null; then
  echo "${RUNTIME_DIR}/" >> "$GITIGNORE"
  echo "  Added ${RUNTIME_DIR}/ to .gitignore"
fi

echo ""
echo "================================================================"
echo "  Installation complete!"
echo "================================================================"
echo ""
echo "  Installed to: $SKILL_DIR/"
echo ""
echo "  Files:"
echo "    $SKILL_DIR/SKILL.md"
echo "    $SKILL_DIR/homer.config"
echo "    $SKILL_DIR/scripts/homer.sh"
echo "    $SKILL_DIR/scripts/homer-prompt.md"
echo ""
echo "  Usage:"
echo "    cd $TARGET_DIR"
echo "    /homer 2                    # via Claude Code skill"
echo "    bash $SKILL_DIR/scripts/homer.sh --epic 2   # direct"
echo ""
echo "  To reconfigure: re-run this installer or edit $SKILL_DIR/homer.config"
echo "================================================================"
