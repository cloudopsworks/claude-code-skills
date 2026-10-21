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
- `README.md` is generated output and must be regenerated with `tronador readme build` as the last documentation step.
- When documentation changes, edit `README.yaml` first, then regenerate `README.md`.
- Run `tronador docs targets` first when Makefile targets or dependency documentation changed.
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
- Direct Make commands are deprecated for README and Git-flow/version operations. Use `tronador readme build`, `tronador docs targets`, and `tronador versions ...` instead; retain the Makefile and unrelated repository-specific Make commands.
- After verifying the corresponding merge completed, destructive cleanup must use `tronador versions feature purge ... --allow-network`, `tronador versions hotfix purge ... --allow-network`, or `tronador versions release purge ... --allow-network`. Fail closed if the WayOfWork policy, merge evidence, authentication, or remote state is missing or contradictory; do not fall back to Make. For a GitFlow release merged into `support/*`, the release must also be back-integrated into `develop` before purge; otherwise Tronador intentionally refuses deletion. CI jobs must install the CLI first with `uses: cloudopsworks/install-tronador-cli@v1`.

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
- Verify the canonical `# Agents: WayOfWork=githubflow` selector before branch operations. Missing, unsupported, or contradictory metadata is a blocker.
- Start work with `tronador versions feature start "<slug>"`. This command is WayOfWork-aware: GitFlow bases from `develop`; GitHubFlow and trunk-based flows use the configured primary branch.
- Generate `.cloudopsworks/_VERSION` only after `cw-release` verifies GitHub-template authority or the bounded canonical skills source-owner exception (trusted repository identity, known template status, regular non-symlink `.cloudopsworks/.skills`, supported selector, and corroborating source policy). When authorized, run `tronador project version --generate --yes`, then review, stage, commit, and submit the file through the normal PR flow. Generation changes only the file; it does not commit, tag, push, or publish. Marker presence or inherited prose alone never grants authority.
- Wait for GitHub checks before merging the PR.
- Use conventional commits for authored commits and merge the PR with a merge commit so GitVersion can read the merge body semver annotation.
- Never push directly to `main`, and do not squash-merge or rebase-merge release PRs.
- Tagging, publishing, and GitHub Release creation for this repository are handled by GitHub Actions after merge; do not create or edit GitHub releases manually as part of the normal workflow.
- **This repository is the canonical CloudOps Works skills source repository for the workflows under `.github/workflows/` and owns those workflow files directly.** They are not generated from an upstream template, so workflow changes are made here. For `cw-release` workflow policy, this explicit source-repository status sets `IS_TEMPLATE=true` solely for the workflow guards. It is independent of `SKILLS_SOURCE_OWNER`, does not assert `GH_IS_TEMPLATE=true`, does not by itself grant `_VERSION` write authority, and does not change this repository's CI-owned publication policy.
- README generation uses the `tronador` CLI, not a direct `make` call. The `auto-readme` workflow installs it with `cloudopsworks/install-tronador-cli@v1` and runs `tronador readme build`. In this repository, that command also prepares `README.yaml.include` and rebuilds the declared `README_DEPS` (`docs/targets.md`) before rendering `README.md`; use `tronador docs targets` when only target documentation needs refreshing.
