# Plans — co-planning vault

This is a **shared live-edit surface** between you and your AI pair. A plan is just a markdown
file on disk: the agent writes it, you edit it in Obsidian, the agent reads your edits next
turn. No build, no sync service — the file *is* the collaboration.

## How to use it

1. Open this folder as a vault in Obsidian (it is auto-registered by `ensure-plan-vault.sh`).
2. Turn on **Live Preview** so headings, checklists, and Mermaid diagrams render inline.
3. When a feature starts, the agent writes `plans/<branch-short-name>.md` from `_template.md`.
4. Review it in Obsidian. Edit anything — reorder phases, check boxes, add constraints,
   answer `> [!question]` callouts inline. The agent reads the file back and incorporates it.
5. When the plan is agreed, the agent executes against it and ticks tasks as they land.

## Conventions

- One file per feature/branch, named after the branch short-name.
- `_template.md` is the starting shape — copy it, never edit it in place.
- **Callouts appear only in "Open questions & decisions"**, and only use valid Obsidian
  types: `> [!question]` (open, purple) and `> [!success] Decision — …` (locked, green).
- **Checkboxes only where things get ticked off** (definition-of-done + phase tasks).
  Constraints and risks are plain bullets.
- Meta is a horizontal table; one blank line between sections; `##` sections, `###` phases.
- Always include a Mermaid `flowchart` dependency graph, with fork/join where phases branch.

## Index

Plans live in `plans/`. Newest work at the top — keep this list current.

- (no plans yet)
