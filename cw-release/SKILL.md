---
name: cw-release
version: 1.1.0
description: |
  CloudOps Works Terraform module full release workflow. Automates the entire
  tronador gitflow cycle: branch creation, conventional commit, push,
  make gitflow/version/file, PR creation, checks wait, merge, tag, publish,
  and GitHub release with changelog. Use when asked to "release", "ship a fix",
  "create a fix branch", "hotfix", "feature branch and PR", or "merge and tag".
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Grep
  - Glob
  - AskUserQuestion
---

# CloudOps Works Release Skill (`/cw-release`)

You are executing the full CloudOps Works tronador gitflow release workflow for a
Terraform module repository. Follow every step in order. Never skip steps. Never
ask for unnecessary confirmation — proceed autonomously unless a STOP point is reached.

---

## Step 0: Environment Check

```bash
git remote -v
git branch --show-current
git status --short
cat .cloudopsworks/_VERSION 2>/dev/null || cat .github/_VERSION 2>/dev/null || echo "NO_VERSION_FILE"
git tag --sort=-v:refname | head -3
git log --oneline -5
```

Verify:
- We are in a git repository with a valid remote.
- The current branch is `master` (or `main`). If not, **STOP** and ask the user if they want to continue from a non-master branch.
- Capture: `CURRENT_VERSION` (from `_VERSION` file or latest tag), `REPO_SLUG` (from remote URL, e.g. `cloudopsworks/terraform-module-template`), `MAIN_BRANCH` (`master` or `main`).

**Detect repository type** — run:
```bash
ls versions.tf .cloudopsworks/.provider 2>/dev/null | head -1
```

- If either `versions.tf` **or** `.cloudopsworks/.provider` exists → set `IS_TEMPLATE=false` (implementation repo).
- If neither exists → set `IS_TEMPLATE=true` (template repository).

Capture: `IS_TEMPLATE` (`true` / `false`). This controls whether Step 12 (tag & publish) runs.

---

## Step 1: Analyze Changes

```bash
git diff HEAD --name-only
git diff HEAD --stat
git diff HEAD
```

Read and understand what changed. Identify:
- **Nature of change**: documentation fix, bug fix, new feature, provider upgrade, breaking change, workflow/template upgrade.
- **Files touched**: classify each file as docs, implementation, workflow, boilerplate, or config.

**STOP HERE** if there are no unstaged/uncommitted changes AND no user-specified content to commit. Tell the user: "No changes detected. Nothing to release."

---

## Step 2: Determine Branch Type and Semver Level

Use the table below to auto-select branch type and semver level from the nature of changes. If ambiguous, use `AskUserQuestion`.

| Change Nature                            | Branch Type | Semver Level | Annotation          |
|------------------------------------------|-------------|--------------|---------------------|
| Docs-only fix / wording correction       | `hotfix`    | PATCH        | `+semver: patch`    |
| Workflow / template upgrade (patch)      | `hotfix`    | PATCH        | `+semver: patch`    |
| Bug fix in implementation                | `fix`       | PATCH        | `+semver: fix`      |
| Workflow / template upgrade (minor)      | `feature`   | MINOR        | `+semver: minor`    |
| New module feature                       | `feature`   | MINOR        | `+semver: feature`  |
| Provider upgrade (backwards-compatible)  | `feature`   | MINOR        | `+semver: minor`    |
| Provider major upgrade / breaking change | `feature`   | MAJOR        | `+semver: major`    |

> **Reminder:** `+semver: breaking` triggers MINOR, not MAJOR. Use `+semver: major` for true breaking changes.

Capture: `BRANCH_TYPE` (`fix`, `hotfix`, `feature`), `SEMVER_ANNOTATION`, `SEMVER_LEVEL`.

---

## Step 3: Determine Branch Name

For `hotfix` branches, tronador auto-names them with the version bump:
```bash
make gitflow/hotfix/start
BRANCH=$(git branch --show-current)
```

For `fix` or `feature` branches, derive a short slug from the changed files or change
nature (max 30 chars, kebab-case, no special chars). Examples: `agents-md-guidelines`,
`vpc-outputs`, `provider-upgrade-v5`.

For `fix`:
```bash
git checkout -b fix/<slug> <MAIN_BRANCH>
BRANCH="fix/<slug>"
```

For `feature`:
```bash
make gitflow/feature/start-no-develop:<slug>
BRANCH="feature/<slug>"
```

Verify the branch was created:
```bash
git branch --show-current
```

---

## Step 4: Stage and Commit

Stage only the changed files relevant to this release. Do not stage unrelated files,
`.env`, credentials, or generated files unless they are `_VERSION` or `_CHANGELOG`.

```bash
git add <files>
git status
```

Craft a conventional commit message following this format:
```
<type>: <concise description of what changed> <SEMVER_ANNOTATION>
```

Where `<type>` is one of: `fix`, `feat`, `docs`, `refactor`, `chore`, `build`.

The message body (multi-line) should enumerate the specific changes as bullet points.
Do NOT describe the semver level in prose — only include the annotation keyword.

Example:
```bash
git commit -m "$(cat <<'EOF'
fix: improve AGENTS.md guidelines with outputs section and dependency management

- Add Outputs guidelines section with copyright header and sensitive flag rules
- Add Module Dependency Management section for git submodule handling
- Clarify publish-first workflow for feature branches
- Fix wording: 'Use make as been provided' -> 'Use make as provided'

+semver: fix
EOF
)"
```

---

## Step 5: Push Branch to Remote

```bash
git push origin <BRANCH>
```

Verify the push succeeded (exit code 0). If it fails due to an upstream tracking issue:
```bash
git push --set-upstream origin <BRANCH>
```

---

## Step 6: Run `make gitflow/version/file`

This writes the computed version to `.cloudopsworks/_VERSION` or `.github/_VERSION`,
commits `chore: Version Bump`, and pushes to the current branch.

```bash
make gitflow/version/file
```

Capture the new version from the output or by reading the version file:
```bash
cat .cloudopsworks/_VERSION 2>/dev/null || cat .github/_VERSION 2>/dev/null
```

Capture: `NEW_VERSION` (e.g. `v1.7.0`).

**STOP** if make fails. Show the error and ask the user how to proceed.

---

## Step 7: Create Pull Request

Build the PR body with `+semver: <level>` in the **body** (not just the title) so
GitVersion picks it up during merge.

```bash
gh pr create \
  --repo <REPO_SLUG> \
  --base <MAIN_BRANCH> \
  --head <BRANCH> \
  --title "<type>: <concise description>" \
  --body "$(cat <<'EOF'
## Summary

<Bullet list of what changed — same bullets as commit body>

<SEMVER_ANNOTATION>
EOF
)"
```

Capture: `PR_NUMBER` from the output URL (last path segment).

---

## Step 8: Wait for CI Checks

```bash
gh pr checks <PR_NUMBER> --repo <REPO_SLUG> --watch
```

If the command exits with "no checks reported": the repo has no CI configured for
this branch. Treat as passing — proceed to Step 9.

If any check **fails**: **STOP**. Report the failed check name and logs. Do not merge.
Ask the user: "Check `<name>` failed. Fix and re-push, or force-merge?"

---

## Step 9: Merge the Pull Request

Use a proper merge commit (never squash or rebase) with `+semver: <level>` in the body:

```bash
gh pr merge <PR_NUMBER> --repo <REPO_SLUG> --merge \
  --subject "chore: merge <BRANCH> - <short description> <SEMVER_ANNOTATION>" \
  --body "$(cat <<'EOF'
## Summary

<Same bullet list as PR body>

<SEMVER_ANNOTATION>
EOF
)" --delete-branch=false
```

Verify merge:
```bash
gh pr view <PR_NUMBER> --repo <REPO_SLUG> --json state,mergedAt
```

Confirm `"state":"MERGED"`.

---

## Step 10: Sync Master

```bash
git checkout <MAIN_BRANCH>
git pull origin <MAIN_BRANCH>
git log --oneline -5
```

Confirm the merge commit appears in the log.

---

## Step 11: Clean Up Local Branch (optional)

Only delete if branch type is `fix` or `feature` (hotfix branches are tracked by tronador).
Ask user: "Delete local branch `<BRANCH>`?"

If yes:
```bash
git branch -d <BRANCH>
```

---

## Step 12: Tag and Publish (Template Repositories Only)

> **This step is skipped for implementation repositories.**
> Tag and publish via `make` is only applicable to **template repositories**
> (those without `versions.tf` or `.cloudopsworks/.provider`).
> For implementation repos, CI automatically creates the tag and release
> when the merge commit is pushed to `master`.

**If `IS_TEMPLATE=false` → skip this entire step and proceed to Step 13.**

If `IS_TEMPLATE=true`, run both targets:

```bash
make gitflow/version/tag gitflow/version/publish
```

Capture the tag name from output (e.g. `Tagged v1.7.0...`). Confirm:
```bash
git tag --sort=-v:refname | head -3
```

**STOP** if tagging fails with "must be in the latest commit of the branch". This means
remote is ahead — run `git pull origin <MAIN_BRANCH>` and retry.

**If `make` exits non-zero with "already exists"** — the CI beat us to it (tag pushed by
the release workflow). This is normal for implementation repos — verify with:
```bash
git fetch --tags && git tag --sort=-v:refname | head -3
```
Proceed to Step 13.

---

## Step 13: Build Changelog

Get commits between the previous tag and the new tag:

```bash
PREV_TAG=$(git tag --sort=-v:refname | sed -n '2p')
NEW_TAG=$(git tag --sort=-v:refname | head -1)
git log ${PREV_TAG}..${NEW_TAG} --pretty=format:"%H|%s|%an|%ad" --date=short
```

Classify each commit:
- `fix:` / `docs:` / `refactor:` → **Bug Fixes & Improvements**
- `feat:` → **New Features**
- `chore:` Version Bump → skip (bookkeeping)
- `chore:` merge → include as PR reference

Build the release body in Markdown:

```markdown
## What's Changed

### <Category>

- **Description**: Full explanation of what was added/fixed/changed.
  - Sub-bullet for detail

### <Next Category>

...

## Commits

| Commit | Description |
|--------|-------------|
| [`<short-sha>`](<commit-url>) | <subject> |

## Full Changelog

https://github.com/<REPO_SLUG>/compare/<PREV_TAG>...<NEW_TAG>
```

Where `<commit-url>` = `https://github.com/<REPO_SLUG>/commit/<full-sha>`.

---

## Step 14: Create or Update GitHub Release

First check if the release already exists (CI may have auto-created it):

```bash
gh release view <NEW_TAG> --repo <REPO_SLUG> 2>/dev/null && echo "EXISTS" || echo "NOT_FOUND"
```

**If NOT_FOUND:** create it:
```bash
gh release create <NEW_TAG> \
  --repo <REPO_SLUG> \
  --title "<NEW_TAG> - <Short Description>" \
  --notes "<changelog from Step 13>"
```

**If EXISTS:** update it (CI may have written a stub):
```bash
gh release edit <NEW_TAG> \
  --repo <REPO_SLUG> \
  --title "<NEW_TAG> - <Short Description>" \
  --notes "<changelog from Step 13>"
```

Output the release URL.

---

## Step 15: Final Summary

Print a concise summary:

```
## Release Complete

- Branch:   <BRANCH>
- PR:       #<PR_NUMBER>  (<URL>)
- Version:  <PREV_VERSION> → <NEW_TAG>
- Tag:      <NEW_TAG> (pushed)
- Release:  <release URL>
```

---

## Rules and Edge Cases

- **Never push directly to master.** Always use a branch.
- **Never squash or rebase on merge.** Always `--merge`.
- **`+semver:` annotation must be in the body of the merge commit**, not just the title, for GitVersion to pick it up.
- **`make gitflow/version/file` commits and pushes.** Do not re-commit or re-push after it runs.
- **`make gitflow/hotfix/start` auto-names the branch** with the bumped patch version. Capture the branch name after running it.
- **Release "already exists" is normal** — CI workflows often auto-create a release from the tag push. Use `gh release edit` in that case.
- **If `gh pr checks` reports "no checks"** — this is valid for branches without CI. Proceed to merge.
- **Git lock files** (`.git/index.lock`): if encountered, run `rm -f .git/index.lock` before retrying.
- **Stale hotfix branches**: if `make gitflow/hotfix/start` fails with a branch-exists error, check with `git branch -a | grep hotfix` and delete stale ones with `git branch -D hotfix/<version>`.
- **Never use `--no-verify`** on commits or pushes.
- **`fix/` branches** are not natively supported by tronador gitflow targets (which only recognize `feature/` and `hotfix/`). Create them manually with `git checkout -b fix/<name>` and manage PR lifecycle with `gh` CLI directly.
- **Template vs Implementation detection** (Step 0 / Step 12):
  - `IS_TEMPLATE=false` when `versions.tf` **or** `.cloudopsworks/.provider` exists → implementation repo → skip `make gitflow/version/tag gitflow/version/publish`.
  - `IS_TEMPLATE=true` only when neither file exists → template repo → run tag & publish.
  - If detection is ambiguous, check the repo name: `terraform-module-template` = template; any other `terraform-module-*` = implementation.