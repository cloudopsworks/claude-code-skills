---
name: cw-readme
version: 1.0.0
description: |
  CloudOps Works README maintenance workflow. Treats README.yaml as the source
  of truth, updates repository documentation in YAML-first format, and runs
  `make readme` as the last step to regenerate README.md.
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Grep
  - Glob
---

# CloudOps Works README Skill (`/cw-readme`)

Use this skill when a repository follows the CloudOps Works documentation model
where `README.yaml` is the source of truth and `README.md` is generated from it.

## Rules

- Treat `README.yaml` as the only maintained source document.
- Update `README.md` only by running `make readme` as the final step.
- Preserve repository-specific documentation conventions from the active `AGENTS.md`.
- If the task includes committing the documentation changes, follow the repo's
  commit policy from `AGENTS.md`. Default to a conventional-commit subject
  line, and append any required repo-local trailers or annotations.
- Prefer concise, operator-friendly documentation written in human-readable Markdown blocks inside YAML fields.

## Workflow

1. Read the repository `AGENTS.md` documentation guidance.
2. Inspect the current `README.yaml` structure and existing generated `README.md`.
3. Update `README.yaml` fields such as:
   - `name`
   - `description`
   - `introduction`
   - `usage`
   - `examples`
   - `quickstart`
   - `badges`
   - `contributors`
4. If examples or command snippets changed, ensure referenced files/scripts actually exist.
5. Run `make readme` last.
6. Verify `README.md` reflects the new YAML content.
7. If the user asked for a commit, stage only the documentation changes and
   create the commit using the repo's required conventional-commit format.

## Expected output

- Updated `README.yaml`
- Regenerated `README.md`
- Brief summary of documentation changes and any remaining gaps
