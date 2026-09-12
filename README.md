# makerspace_claude_skills

Reusable Claude tooling for the makerspace — **skills** (which double as slash
commands) and, only where truly needed, MCP servers. Tooling lives here; the
per-workshop **data** lives in separate context vaults (e.g. the Westbound
Workshop Obsidian vault). See [`PLAN.md`](PLAN.md) for the full roadmap and the
decisions behind this split.

## Install

```sh
./install.sh
```

Symlinks each `skills/<name>` → `~/.claude/skills/<name>`, so every local Claude
Code session (Conductor local + terminal) sees them in any directory. A skill
only costs its name + one-line description until it's invoked, so a global
install stays cheap even in unrelated repos. The script is self-locating and
idempotent.

> Run `install.sh` from a **stable checkout** (e.g.
> `~/Documents/git/makerspace_claude_skills`), never a Conductor worktree —
> worktrees get archived, which would leave broken symlinks. The script warns if
> you run it from a worktree.

## Layout

```
install.sh              # idempotent, self-locating; skills/* -> ~/.claude/skills/*
config/
  workshops.toml        # workshop id -> vault path + inventory folder
skills/
  tool-advisor/         # "what can my shop do?"; feeds constraints to other skills
    SKILL.md
    references/inventory-format.md
  fusion-start/         # launch Fusion, verify its MCP server, open a new design
    SKILL.md
    scripts/check-mcp.sh        # layer-by-layer probe of the Fusion MCP endpoint
    references/troubleshooting.md
  gridfinity/           # object dimensions -> parametric bin -> headless STL
    SKILL.md
    scripts/generate.py         # sizing + render driver
    vendor/gridfinity-rebuilt/  # pinned upstream OpenSCAD lib (MIT)
    references/gridfinity-spec.md
```

> `gridfinity` needs the OpenSCAD **snapshot/nightly** build
> (`brew install --cask openscad@snapshot`) — the vendored library uses syntax
> the 2021.01 stable release can't parse.

## Skills

- **`/tool-advisor`** — capability Q&A over a per-tool inventory in the workshop
  vault ("can I cut X on my Y?", "what bit for Z?"), and supplies hard
  constraints (print-bed size, throat depth) to other skills.
- **`/gridfinity`** — research an object's dimensions → parametric Gridfinity bin
  → headless STL + params manifest, sized to the printer bed from `tool-advisor`.
- **`/fusion-start`** — launch Autodesk Fusion, confirm its built-in MCP server
  (`127.0.0.1:27182/mcp`) answers and is registered with Claude, then open a new
  design document. `scripts/check-mcp.sh` diagnoses each layer when it doesn't.

> `fusion-start` needs the **Fusion MCP Server** switched on in Fusion
> (Preferences > General > API) and a `fusion` MCP entry in Claude Code:
> `claude mcp add --transport http --scope user fusion http://127.0.0.1:27182/mcp`

## Configuration

`config/workshops.toml` maps a workshop id to its context vault and inventory
folder. Skills read it relative to their own directory, so there's one source of
truth. Add a second `[workshops.*]` block for Arch Reactor when its vault exists.
