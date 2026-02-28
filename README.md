# HomerSimpson-BMAD

A sequential story **creator** for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) using the [Ralph Wiggum method](https://www.geoffreyhuntley.com/ralph-wiggum).

Each story gets a **fresh `claude -p` process** with zero context accumulation. Homer reads epics + architecture docs and produces ready-for-dev story files — the planning complement to [RalphWiggum-BMAD](https://github.com/OFurtun/RalphWiggum-BMAD) (which executes them).

Works with [BMAD-METHOD](https://github.com/OFurtun/BMAD-METHOD) projects out of the box. Also works with any project that has markdown epics and a sprint-status YAML file.

## Quick Start

```bash
# Clone the installer
git clone https://github.com/OFurtun/HomerSimpson-BMAD.git /tmp/homer-installer

# Install into your project
/tmp/homer-installer/install.sh /path/to/your/project

# Create stories (from your project directory)
cd /path/to/your/project
/homer 2                    # via Claude Code skill
# or
bash .claude/skills/homer/scripts/homer.sh --epic 2   # direct
```

## What It Does

For each backlog story in an epic:

1. **Homer** (a fresh `claude -p`) reads the epics file, architecture docs, and previous stories
2. Performs a 6-step analysis: target identification, artifact analysis, architecture deep dive, web research, story file creation, cross-verification
3. Writes a comprehensive ready-for-dev story file with embedded SQL, exact file paths, test approaches, and cross-cutting concerns
4. Updates sprint-status.yaml from `backlog` to `ready-for-dev`
5. Loop continues to the next story

```
homer.sh (bash loop)           <- Zero intelligence. Parses signals, calls processes.
    |
    +-- claude -p (Homer)      <- Fresh process per story. Reads docs. Writes story file.
```

## Architecture

```
                              /homer --epic N
                                    |
                    +--------------------------------+
                    |          SKILL.md              |
                    |                                |
                    |  Validate prerequisites        |
                    |  Discover backlog stories      |
                    |  Initialize PROGRESS.md        |
                    +---------------+----------------+
                                    |
     +------------------------------v-------------------------------+
     |                       homer.sh                               |
     |                  "Zero intelligence bash loop"               |
     |                                                              |
     |  +---------------------------------------------------------+ |
     |  |  OUTER LOOP - for each backlog story (sequential)       | |
     |  |                                                         | |
     |  |  Read PROGRESS.md -> skip created/blocked -> start      | |
     |  |                                                         | |
     |  |  +---------------------------------------------------+  | |
     |  |  |  INNER LOOP - continuations (max 3 per story)     |  | |
     |  |  |                                                   |  | |
     |  |  |  +---------------------------------------+        |  | |
     |  |  |  |    Fresh claude -p  (Homer)           |        |  | |
     |  |  |  |    Zero context accumulation          |        |  | |
     |  |  |  |                                       |        |  | |
     |  |  |  |  Reads:                               |        |  | |
     |  |  |  |   * Epics file (full epic context)    |        |  | |
     |  |  |  |   * Architecture docs (full shards)   |        |  | |
     |  |  |  |   * Previous story file               |        |  | |
     |  |  |  |   * PROGRESS.md (relay baton)         |        |  | |
     |  |  |  |   * Web (latest versions, advisories) |        |  | |
     |  |  |  |                                       |        |  | |
     |  |  |  |  Does:                                |        |  | |
     |  |  |  |   * 6-step analysis process           |        |  | |
     |  |  |  |   * Writes story file                 |        |  | |
     |  |  |  |   * 3-pass cross-verification         |        |  | |
     |  |  |  +------------------+--------------------+        |  | |
     |  |  |                     |                             |  | |
     |  |  |            +--------+--------+-----------+        |  | |
     |  |  |            v                 v           v        |  | |
     |  |  |         CREATED          BLOCKED     MAX-TURNS    |  | |
     |  |  |            ok               x        (no signal)  |  | |
     |  |  |            |                |           |         |  | |
     |  |  |            |                |      file modified? |  | |
     |  |  |            |                |       /        \    |  | |
     |  |  |            |                |     YES         NO  |  | |
     |  |  |            |                |      |           |  |  | |
     |  |  |            |                |  CONTINUE     BLOCK |  | |
     |  |  +------------+----------------+---------------------+  | |
     |  |               |                |                        | |
     |  |               v                v                        | |
     |  |          next story         HALT (default)              | |
     |  +---------------------------------------------------------+ |
     +--------------------------------------------------------------+

              +----------- Shared State -------------+
              |                                      |
              |  PROGRESS.md       sprint-status     |
              |  (relay baton)     (.yaml)           |
              |  +-------------+   +--------------+  |
              |  | Story table |   | backlog      |  |
              |  | Relay notes |   | ready-for-dev|  |
              |  | Attempts    |   | in-progress  |  |
              |  +-------------+   +--------------+  |
              |                                      |
              |  BLOCKERS.md       story-N.M-record  |
              |  (failure log)     (creation log)    |
              |  +-------------+   +--------------+  |
              |  | Issue       |   | Shards read  |  |
              |  | Attempted   |   | Web research |  |
              |  | Needs       |   | Issues fixed |  |
              |  +-------------+   +--------------+  |
              +--------------------------------------+
```

Each `claude -p` invocation is a **disposable worker** with zero memory. The only things that survive between runs are **PROGRESS.md** (the relay baton) and the **story files** (the output). Homer reads docs and writes stories — no code, no git, no tests.

## Homer + Ralph Pipeline

Homer and Ralph are complementary:

```
Homer (SM)                  Ralph (Dev)                 Review
  |                           |                           |
  +-- Create story files ---> +-- Execute stories ------> +-- Code review
  |   (backlog -> ready)      |   (ready -> done)         |   (fresh context)
  |                           |                           |
  +-- Batch or one-at-a-time  +-- Sequential              +-- Per story
  |   Fresh context per story |   Fresh context per story |
  |   Reads: epics, arch      |   Reads: story file       |
  |   Writes: story files     |   Writes: code, commits   |
```

## Installation

```bash
./install.sh [project-directory]
```

The interactive installer:
1. Asks which project to install into
2. Detects BMAD (sets defaults automatically) or uses generic defaults
3. Configures epics, architecture, sprint-status, and output paths
4. Copies everything into `{project}/.claude/skills/homer/`
5. Generates a `homer.config` with your settings

### What Gets Installed

```
your-project/
+-- .claude/skills/homer/
    |-- SKILL.md                    # Claude Code skill definition (/homer)
    |-- homer.config                # Your project-specific configuration
    +-- scripts/
        |-- homer.sh                # Bash loop orchestrator
        +-- homer-prompt.md         # Homer's system prompt
```

### Configuration

| Setting | BMAD Default | Generic Default |
|---------|-------------|-----------------|
| Epics file | `_bmad-output/planning-artifacts/epics.md` | `docs/epics.md` |
| Architecture docs | `_bmad-output/planning-artifacts/architecture` | `none` |
| Sprint status | `_bmad-output/implementation-artifacts/sprint-status.yaml` | `sprint-status.yaml` |
| Story output | `_bmad-output/implementation-artifacts` | `stories` |
| Runtime directory | `_homer` | `_homer` |

Edit `homer.config` anytime to reconfigure, or re-run `install.sh`.

## Usage

```bash
# Create all backlog stories in an epic
/homer 2
homer.sh --epic 2

# Create only the first 3 backlog stories
homer.sh --epic 2 --count 3

# Start from a specific story
homer.sh --epic 2 --start-from 2.4

# Retry previously blocked stories
homer.sh --epic 2 --retry-blocked

# Continue past blocks (don't halt pipeline)
homer.sh --epic 2 --no-halt-on-block

# Preview without executing
homer.sh --epic 2 --dry-run

# Full help
homer.sh --help
```

## How It Works

### Story Discovery

Homer discovers stories from `sprint-status.yaml`, not from file globs. This is because story files **don't exist yet** — Homer creates them.

```yaml
# sprint-status.yaml
development_status:
  epic-2: backlog
  2-1-rlm-engine-core: backlog        # <-- Homer will create this
  2-2-chat-data-model: backlog         # <-- and this
  2-3-pwa-chat-interface: ready-for-dev # <-- skip (already created)
```

### The 6-Step Process

Each `claude -p` invocation follows this process:

1. **Determine Target** — Parse epic/story number from prompt context
2. **Load & Analyze Artifacts** — Read epics, cross-cutting concerns, decisions register, previous story
3. **Architecture Deep Dive** — Read full architecture shards (never grep fragments), extract canonical DDL, RLS policies, test patterns
4. **Web Research** — Latest versions, breaking changes, security advisories
5. **Create Story File** — Write comprehensive ready-for-dev story with embedded SQL, exact file paths, mapped ACs
6. **Cross-Verification** — 3 sequential passes: schema, requirements, patterns. Fix all issues in-place

### The Relay Baton

`_homer/PROGRESS.md` carries state between iterations:

```markdown
## Stories
| Key | Slug | Status | Attempts | Notes |
|-----|------|--------|----------|-------|
| 2.1 | 2-1-rlm-engine-core | ready-for-dev | 1 | created 2025-02-27 |
| 2.2 | 2-2-chat-data-model | in-progress | 1 | |
| 2.3 | 2-3-pwa-chat-interface | pending | 0 | |

## Relay Notes
### Story 2.1
- ACs: 15
- Architecture shards: entity-model, rlm-engine, cross-cutting
- Key patterns: runAgentLoop(), SSE adapter, pg-boss adapter
```

### Completion Signals

Homer outputs one of:
- `<promise>STORY-N.M-CREATED</promise>` — story file created
- `<promise>STORY-N.M-BLOCKED:reason</promise>` — story blocked

### Continuation on Max-Turns

If Homer hits the turn limit but the output file was modified (partial story created), it launches a continuation (up to 3 per story) with a fresh `claude -p` that reads the partial file and continues.

### Story Quality Rules

Homer enforces these rules on every story it creates:

- Never copy epics verbatim — transform into actionable dev instructions
- Never say "paste from source" — embed the actual SQL/code
- Never leave ACs vague — every AC must have a verifiable condition
- Always embed exact SQL for every DDL, function, policy, and index
- Always include file paths — exact paths where code should be created/modified
- Always map Tasks to ACs — every task references which ACs it satisfies
- Max 20 ACs — if more are needed, the story should be split
- Cross-cutting concerns are explicit ACs — not just mentioned in Dev Notes

## Prerequisites

Homer needs these artifacts to exist in your project:

1. **Epics file** — Markdown with epic/story definitions, acceptance criteria, cross-cutting concerns, decisions register
2. **Sprint status** — YAML file with `development_status` section listing stories and their statuses
3. **Architecture docs** (recommended) — Homer reads these for canonical schemas, patterns, and constraints

See `examples/` for templates.

## Requirements

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI (`claude` command)
- `bash` 4+
- `awk`

## Credits

- **Ralph Wiggum Method**: [Geoffrey Huntley](https://www.geoffreyhuntley.com/ralph-wiggum) (February 2025)
- **Relay Baton Pattern**: [Anand Chowdhary](https://anandchowdhary.com/blog/ralph-wiggum)
- **BMAD Method**: [BMAD-METHOD](https://github.com/OFurtun/BMAD-METHOD)

## License

MIT
