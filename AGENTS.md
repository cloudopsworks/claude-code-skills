# Repository Instructions

This repository packages CloudOps Works agent skills for multiple clients.

## Primary automation rule

When changing, adding, or removing a skill, keep installation automation current for all supported targets:
- Claude Code
- OpenCode
- Codex

For this repository, every top-level directory containing `SKILL.md` is a distributable CloudOps Works skill.

Install and upgrade automation must be maintained in:
- `scripts/install-cloudopsworks-skills.sh`
- `scripts/upgrade-cloudopsworks-skills.sh`

Backward-compatible single-skill wrappers may exist, but the generic multi-skill installers are the source of truth.

## Installation contract

- Claude Code installs full skill directories under `~/.claude/skills/`.
- Codex installs full skill directories under `~/.codex/skills/` or `$CODEX_HOME/skills/`.
- OpenCode installs generated command files under `~/.config/opencode/commands/` or `$OPENCODE_HOME/commands/`.
- Default behavior should favor low-maintenance automation:
  - auto-discover current repo skills from top-level `*/SKILL.md`
  - symlink for directory-based targets when safe
  - forceable overwrite for upgrades
  - generated OpenCode command output derived from each skill's `SKILL.md`

## Documentation treatment

- `README.yaml` is the maintained source of truth for repository documentation.
- `README.md` is generated output and must be regenerated with `make readme` as the last documentation step.
- When documentation changes, edit `README.yaml` first, then regenerate `README.md`.
- Prefer adding reusable documentation workflow help as a `cw-` skill when it reduces repeated manual guidance.

## Agent expectations

- Prefer updating the install/upgrade scripts over writing manual install steps.
- Keep README installation instructions aligned with the scripts.
- If any skill `SKILL.md` changes materially, ensure the generated OpenCode output still reflects the latest skill content.
- If a new skill directory is added at the repository root with `SKILL.md`, installation scripts should pick it up without requiring hardcoded lists.
- Verify installer changes by running them against an isolated temporary home before claiming completion.
- Do not introduce new dependencies for installation automation unless explicitly requested.

## Makefile / Tronador contract

- Tronador is required in this repository and must remain included from the Makefile exactly as provided.
- New Make targets may be added when needed, but the Tronador include must not be removed, duplicated, superseded, or replaced by a local reimplementation.
- Treat Tronador-provided behavior as the source of truth for shared automation; extend around it instead of overriding it.

## Verification requirements

After installer changes, verify at minimum:
- auto-discovery finds the expected skills
- Claude Code target creates `skills/<skill>/SKILL.md`
- Codex target creates `skills/<skill>/SKILL.md`
- OpenCode target creates `commands/<skill>/<skill>.md`
- upgrade scripts replace an existing installation cleanly
- generic scripts work for both current skills and a synthetic future skill added in a temporary verification copy

## Scope

These instructions apply to the repository root and all child paths.

## Release management

- Can use `cw-release` skill for streamlined release processes, but follow this repository's concrete policy over generic template heuristics.
- This repository uses the GitHubFlow-style GitVersion config in `.cloudopsworks/gitversion.yaml` (`main` / `release` / `feature` / `pull-request`, no `develop`).
- For this repository, branch release work from `main` using `feature/*`; do not default to `hotfix/*` or `fix/*` unless a repo-local rule explicitly requires it.
- In this repository's GitVersion config, `+semver: breaking` maps to a **MINOR** bump. Use `+semver: major` for a true MAJOR release.
- `.cloudopsworks/_VERSION` must be updated on the working branch before the PR by running `make gitflow/version/file`.
- Wait for GitHub checks before merging the PR.
- Use conventional commits for authored commits and merge the PR with a merge commit so GitVersion can read the merge body semver annotation.
- Never push directly to `main`, and do not squash-merge or rebase-merge release PRs.
- Tagging, publishing, and GitHub Release creation for this repository are handled by GitHub Actions after merge; do not create or edit GitHub releases manually as part of the normal workflow.
