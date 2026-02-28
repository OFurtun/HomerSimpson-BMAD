---
name: homer
description: "Homer story creator. Creates implementation story files from epics + architecture via fresh claude -p per story."
argument-hint: "[epic-number] [--count N] [--start-from N.M] [--dry-run] [--retry-blocked]"
disable-model-invocation: true
allowed-tools: Bash, Read, Write, Edit, Glob, Grep
---

# Homer Story Creator

You are the setup and launch agent for the Homer story creator pipeline.
Your job is to validate prerequisites, initialize state, and launch the bash loop.
You do NOT create stories yourself — `homer.sh` handles that via fresh `claude -p` processes.

**Homer creates story files** by reading epics + architecture and producing ready-for-dev story files.
Each story gets a fresh `claude -p` process with zero context accumulation.

## Arguments

- `$ARGUMENTS[0]` — Epic number (required unless `--retry-blocked`)
- `--count N` — Create only N stories (default: all backlog stories in epic)
- `--start-from N.M` — Start from a specific story (e.g., `2.3`)
- `--retry-blocked` — Re-attempt previously blocked stories
- `--dry-run` — Show what would execute without running
- `--help` — Show homer.sh usage

## Setup Procedure

### Step 1: Validate Prerequisites

Read `homer.config` (in this skill directory) for configured paths. Check these exist:

1. **Epics file**: Check configured path
   - If missing: "Epics file not found. Create it first."
2. **Architecture docs**: Check configured path
   - If missing: "Architecture docs not found."
3. **Sprint status**: Check configured path
   - If missing: "Sprint status not found. Run sprint-planning first."
4. **Homer scripts**: `.claude/skills/homer/scripts/homer.sh`

### Step 2: Discover Backlog Stories

Parse sprint-status.yaml to find backlog stories for the requested epic.

1. Read the full sprint-status file
2. Extract all entries matching `{epic}-*-*: backlog` for the requested epic number
3. If no backlog stories found: "No backlog stories found for Epic {N}."
4. Apply `--count N` limit if specified
5. Apply `--start-from N.M` filtering if specified
6. Display the story list to the user for confirmation

### Step 3: Initialize PROGRESS.md

If `_homer/PROGRESS.md` doesn't exist (fresh run), create it:

```markdown
# Homer Story Creator Progress

## Run Info
- Epic: {epic_number}
- Started: {timestamp}
- Stories: {count}

## Stories
| Key | Slug | Status | Attempts | Notes |
|-----|------|--------|----------|-------|
| 2.1 | first-story-slug | pending | 0 | |
| 2.2 | second-story-slug | pending | 0 | |
...

## Relay Notes
_Notes from completed stories for the next iteration to read._
```

If `_homer/PROGRESS.md` already exists (resuming), read it and report current state.

Create `_homer/` directory if it doesn't exist.

### Step 4: Launch homer.sh

```bash
bash .claude/skills/homer/scripts/homer.sh --epic "$EPIC_NUM"
```

Pass through any user flags (`--count`, `--start-from`, `--retry-blocked`, `--dry-run`).

Report to the user:
- How many stories will be created
- That they can monitor `_homer/PROGRESS.md` and `_homer/BLOCKERS.md`

### Handling --retry-blocked

1. Read existing `_homer/PROGRESS.md`
2. Find stories with status `blocked`
3. Reset their status to `pending`
4. Launch homer.sh with `--retry-blocked`

### Handling --dry-run

1. Do all setup (list stories, init PROGRESS.md)
2. Display what homer.sh WOULD execute (story list with slugs)
3. Do NOT launch homer.sh
4. User can inspect `_homer/PROGRESS.md` before running

## Notes

- **No branch creation.** Story files are planning artifacts, not code.
- **No git operations.** Homer does not commit. Sprint-status.yaml is the only file homer.sh modifies (backlog -> ready-for-dev).
- **Story files are WRITE targets.** Homer creates story files. It does NOT modify existing story files.
- **Sprint-status is kept in sync** (if configured).
- The `_homer/` directory is auto-added to `.gitignore`.
- `homer.sh` runs as a long-running foreground process.
