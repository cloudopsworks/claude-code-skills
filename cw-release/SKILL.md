---
name: cw-release
version: 1.2.5
description: |
  CloudOps Works release workflow. Detects the repository GitVersion flow and
  repo-local release policy, stays portable across Claude Code, Codex, and
  OpenCode, and then drives the shared tronador make/gh release path.
  Use when asked to "release", "ship a fix", "create a release branch",
  "hotfix", "feature branch and PR", or "merge and tag".
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

You are executing the CloudOps Works release workflow for a repository that may
use either GitFlow or GitHubFlow semantics through GitVersion. Detect the active
flow from `.cloudopsworks/gitversion.yaml`; if the file does not exist, assume
GitFlow. Then detect any repo-local release policy from `AGENTS.md`, version
files, and GitHub workflows before deciding whether versioning happens on-branch,
after merge in CI, or both. Follow every step in order. Never skip flow or
policy detection. Any detected uncommitted changes that are part of the release
must be captured in a new conventional commit before the workflow continues past
staging/commit. Never ask for unnecessary confirmation — proceed autonomously
unless a STOP point is reached.

---

## Runtime Portability Rules

- Treat this document body as the source of truth even when the current tool
  wraps or strips frontmatter (for example generated OpenCode commands).
- Use the current runtime's equivalent shell / read / edit / grep capabilities.
  If the platform names tools differently, execute the same git, gh, make, and
  file-inspection steps with the available equivalents.
- When this skill says `AskUserQuestion`, use the runtime's native question tool
  if available; otherwise ask exactly one concise plain-text question in chat.
- Prefer repo-local policy over generic heuristics when they conflict. In
  particular, if `AGENTS.md` or repo workflows explicitly define version-file,
  merge, or publish behavior, follow those rules even if the repository is not a
  Terraform module. This keeps Claude Code, Codex, and generated OpenCode
  commands aligned on the same release behavior.

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

**Detect GitVersion flow** — run:
```bash
if [ -f .cloudopsworks/gitversion.yaml ]; then
  sed -n '1,220p' .cloudopsworks/gitversion.yaml
else
  echo "MISSING_GITVERSION_CONFIG"
fi
```

Set `RELEASE_FLOW` using this rule:
- If `.cloudopsworks/gitversion.yaml` is missing → `RELEASE_FLOW=gitflow` (default assumption).
- If the config defines `develop:` or `hotfix:` or `support:` branches → `RELEASE_FLOW=gitflow`.
- If the config defines `main`, `release`, `feature`, `pull-request` and does **not** define `develop:` → `RELEASE_FLOW=githubflow`.

Capture: `RELEASE_FLOW` (`gitflow` / `githubflow`).

**Interpret bundled examples carefully:**
- `cw-release/gitflow/gitversion.yaml` = GitFlow reference where `+semver: breaking` implies MAJOR.
- `cw-release/githubflow/gitversion.yaml` = generic GitHubFlow reference where `+semver: breaking` also implies MAJOR.
- `cw-release/githubflow-cloudopsworks-spec/gitversion.yaml` = CloudOps Works GitHubFlow policy, matching this repository, where `+semver: breaking` implies MINOR and `+semver: major` is required for a MAJOR bump.
- When a repository already has `.cloudopsworks/gitversion.yaml`, trust that file over bundled examples.

**Detect repository type** — run:
```bash
ls versions.tf .cloudopsworks/.provider .cloudopsworks/_VERSION 2>/dev/null
gh repo view <REPO_SLUG> --json isTemplate 2>/dev/null || echo '{"isTemplate":null}'
```

- If either `versions.tf` **or** `.cloudopsworks/.provider` exists → set `IS_TEMPLATE=false` (Terraform implementation repo).
- If neither exists → set `IS_TEMPLATE=true` (non-implementation repo by the legacy heuristic).
- If `gh repo view` reports `"isTemplate": true`, treat that as authoritative confirmation that the GitHub repository is a template repository even if the legacy heuristic is inconclusive.
- If `gh repo view` reports `"isTemplate": false`, keep the repo-local heuristic in mind; some repositories behave operationally like templates even when the GitHub template flag is disabled.
- If `gh repo view` is unavailable or unauthenticated, fall back to the repo-local heuristic above.
- If `.cloudopsworks/_VERSION` exists, capture it as a repo-managed version file even when the repo is **not** a Terraform template.
- Set `IS_TEMPLATE=true` when either the repo-local heuristic says template **or** `gh repo view` says `isTemplate=true`.

Capture: `GH_IS_TEMPLATE` (`true` / `false` / `unknown`) and `IS_TEMPLATE` (`true` / `false`). Do **not** use `IS_TEMPLATE` alone to decide publish behavior.

**Detect repo-local release policy** — run:
```bash
sed -n '1,260p' AGENTS.md 2>/dev/null || true
ls .github/workflows/pr-merge-tagging.yml .github/workflows/release-management.yml 2>/dev/null || true
```

Set the following policy flags:
- `RUN_VERSION_FILE_BEFORE_PR=true` when repo-local instructions explicitly require `make gitflow/version/file` before the PR, or when the repo's maintained version file must be updated on-branch.
- `PUBLISH_MODE=ci` when repo-local instructions say releases are handled by GitHub Actions **or** when merge-tagging / release-management workflows clearly own tag + publish after merge.
- `PUBLISH_MODE=local` only when no repo-local CI release owner is detected and the operator is expected to create or edit the tag/release directly.

Capture: `RUN_VERSION_FILE_BEFORE_PR` (`true` / `false`) and `PUBLISH_MODE` (`ci` / `local`). These control Steps 6 and 12-14.

Detect CI requirement from AGENTS.md content:
- `CI_REQUIRED=true` when AGENTS.md contains phrases like "wait for checks", "checks must
  pass", "CI required", "do not merge until checks", or when `PUBLISH_MODE=ci`.
- `CI_REQUIRED=false` when AGENTS.md explicitly says "no CI", "no checks", or the repo has
  no `.github/workflows/` directory.
- `CI_REQUIRED=unknown` when AGENTS.md is silent on the topic (default; resolved in Step 8
  via the GitHub API).

Capture: `CI_REQUIRED` (`true` / `false` / `unknown`).

Detect remote branch preservation requirement:
- `PRESERVE_REMOTE_BRANCH=true` when `PUBLISH_MODE=ci` — CI workflows (e.g.
  `pr-merge-tagging.yml`, `release-management.yml`) run post-merge and may need the
  source branch to remain intact for tagging, GitVersion resolution, or artifact
  attribution. Remote branch deletion must never race with active CI workflows.
- `PRESERVE_REMOTE_BRANCH=false` when `PUBLISH_MODE=local`.

Capture: `PRESERVE_REMOTE_BRANCH` (`true` / `false`). This overrides
`PURGE_RELEASE_BRANCH` for any remote deletion decision in Steps 9 and 11.

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

If unstaged or uncommitted changes are present, they must be turned into a fresh **conventional commit** in Step 4 before any push, PR, merge, tag, or publish action occurs. Do not carry forward ad hoc or non-conventional WIP for release automation.

---

## Step 2: Determine Branch Type and Semver Level

Use the matrix that matches `RELEASE_FLOW` to auto-select branch type and semver level from the nature of changes. If ambiguous, use `AskUserQuestion`.

### If `RELEASE_FLOW=gitflow`

| Change Nature                            | Branch Type | Semver Level | Annotation             |
|------------------------------------------|-------------|--------------|------------------------|
| Docs-only fix / wording correction       | `hotfix`    | PATCH        | `+semver: patch`       |
| Workflow / template upgrade (patch)      | `hotfix`    | PATCH        | `+semver: patch`       |
| Bug fix in implementation                | `hotfix`    | PATCH        | `+semver: fix`         |
| Workflow / template upgrade (minor)      | `feature`   | MINOR        | `+semver: minor`       |
| New module feature                       | `feature`   | MINOR        | `+semver: feature`     |
| Provider upgrade (backwards-compatible)  | `feature`   | MINOR        | `+semver: minor`       |
| Provider major upgrade / breaking change | `feature`   | MAJOR        | `+semver: major`       |
| Explicit compatibility break             | `feature`   | MAJOR        | `+semver: breaking` or `+semver: major` |

> **GitFlow reminder:** in the bundled GitFlow config, `+semver: breaking` and `+semver: major` both trigger a MAJOR bump.

### If `RELEASE_FLOW=githubflow`

| Change Nature                            | Branch Type | Semver Level | Annotation                    |
|------------------------------------------|-------------|--------------|-------------------------------|
| Docs-only fix / wording correction       | `feature`   | PATCH        | `+semver: patch`              |
| Workflow / template upgrade (patch)      | `feature`   | PATCH        | `+semver: patch` or `+semver: hotfix` |
| Bug fix in implementation                | `feature`   | PATCH        | `+semver: fix`                |
| Workflow / template upgrade (minor)      | `feature`   | MINOR        | `+semver: minor`              |
| New module feature                       | `feature`   | MINOR        | `+semver: feature`            |
| Provider upgrade (backwards-compatible)  | `feature`   | MINOR        | `+semver: minor`              |
| Provider major upgrade / breaking change | `feature`   | MAJOR        | `+semver: major`              |
| Explicit compatibility break, but still minor by policy | `feature` | MINOR | `+semver: breaking` |

> **GitHubFlow reminder:** inspect the repository's actual `major-version-bump-message` and `minor-version-bump-message`.
> - In the generic bundled GitHubFlow example, `+semver: breaking` triggers MAJOR.
> - In the CloudOps Works GitHubFlow spec and this repository's config, `+semver: breaking` triggers MINOR.
> Use `+semver: major` whenever you need an unambiguous MAJOR release.

Capture: `BRANCH_TYPE` (usually `feature` or `hotfix`), `SEMVER_ANNOTATION`, `SEMVER_LEVEL`. Avoid `fix/*` as a default branch strategy because it is not a first-class GitVersion branch in either bundled config.

After `BRANCH_TYPE` is known, set `PURGE_RELEASE_BRANCH`:
- If `IS_TEMPLATE=true` **and** `BRANCH_TYPE=feature` → `PURGE_RELEASE_BRANCH=true`
- Otherwise → `PURGE_RELEASE_BRANCH=false`

Template repositories should not retain merged `feature/*` release branches locally or remotely.

---

## Step 3: Determine Branch Name

Choose the branch strategy that matches `RELEASE_FLOW`.

For `RELEASE_FLOW=gitflow` and `BRANCH_TYPE=hotfix`, tronador auto-names the branch with the version bump:
```bash
make gitflow/hotfix/start
BRANCH=$(git branch --show-current)
```

For `feature` branches, derive a short slug from the changed files or change
nature (max 30 chars, kebab-case, no special chars). Examples: `agents-md-guidelines`,
`vpc-outputs`, `provider-upgrade-v5`.

For `RELEASE_FLOW=gitflow` and `BRANCH_TYPE=feature`:
```bash
make gitflow/feature/start-no-develop:<slug>
BRANCH="feature/<slug>"
```

For `RELEASE_FLOW=githubflow`, default to `feature/<slug>` even for patch-only work:
```bash
make gitflow/feature/start-no-develop:<slug>
BRANCH="feature/<slug>"
```

Only use `hotfix/*` in `githubflow` repositories if repo-local automation explicitly expects it (for example workflow conditions, labelers, or docs that reference `hotfix/**`). Do not default to `fix/*` unless the repository clearly documents that convention.

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

All uncommitted changes included in this release must be captured in a **new conventional commit** created in this step. Do not continue with uncommitted work, ad hoc snapshots, or non-conventional commit text.

Craft the commit message following this format:
```
<type>: <concise description of what changed> <SEMVER_ANNOTATION>
```

Where `<type>` is one of: `fix`, `feat`, `docs`, `refactor`, `chore`, `build`. Choose the type that best matches the actual uncommitted changes being released.

The message body (multi-line) should enumerate the specific changes as bullet points.
Do NOT describe the semver level in prose — only include the annotation keyword.
If the active repository `AGENTS.md` requires additional commit trailers or
decision-record metadata, keep the first line in conventional-commit format and
append the repo-required trailers after the bullet list and semver annotation.

**STOP** if the operator attempts to proceed without creating this conventional commit for the current uncommitted changes.

Example:
```bash
git commit -m "$(cat <<'EOF'
fix: improve AGENTS.md guidelines with outputs section and dependency management

- Add Outputs guidelines section with copyright header and sensitive flag rules
- Add Module Dependency Management section for git submodule handling
- Clarify publish-first workflow for feature branches
- Fix wording: 'Use make as been provided' -> 'Use make as provided'

+semver: fix

Constraint: Follow repo-local release and commit policy from AGENTS.md
Confidence: high
Scope-risk: narrow
Tested: reviewed affected release guidance
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

## Step 6: Run `make gitflow/version/file` When Repo Policy Requires It

`make gitflow/version/file` computes the next version from branch history and commits
a `chore: Version Bump` to the working branch. The target name stays under the shared
`gitflow/...` make namespace even in repositories whose GitVersion model is GitHubFlow.

Decision rule:
- If `RUN_VERSION_FILE_BEFORE_PR=true` → run this step, even when the repository is a
  non-Terraform repo such as this skills repository.
- If `RUN_VERSION_FILE_BEFORE_PR=false` and `IS_TEMPLATE=false` → skip this step.
- If `RUN_VERSION_FILE_BEFORE_PR=false` and `IS_TEMPLATE=true` → run this step only if
  the repo has no contrary local release policy.

If skipping, read the current version file (when present) to capture `CURRENT_VERSION`:
```bash
cat .cloudopsworks/_VERSION 2>/dev/null || cat .github/_VERSION 2>/dev/null || true
```

If running, execute:
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

## Step 8: Wait for CI Checks (BLOCKING — never skip or shortcut)

This step is the sole gate before merge. Do not proceed to Step 9 until all checks
pass or CI is confirmed absent. There is no bypass.

**8a. Poll for check registration (max 60 seconds).**

Run the following loop — it exits when at least one check appears or 60 seconds elapse:
```bash
for i in $(seq 1 6); do
  COUNT=$(gh pr view <PR_NUMBER> --repo <REPO_SLUG> \
    --json statusCheckRollup --jq '.statusCheckRollup | length')
  [ "$COUNT" -gt 0 ] && break
  echo "No checks yet (attempt $i/6). Waiting 10s..."
  sleep 10
done
```

**8b. If `COUNT` is still 0 after the loop — determine if CI is expected.**

Use `CI_REQUIRED` captured in Step 0:
- If `CI_REQUIRED=true` → **STOP**: "No checks registered after 60s despite CI being
  required. Investigate GitHub Actions configuration before merging."
- If `CI_REQUIRED=false` → no CI configured; proceed to Step 9.
- If `CI_REQUIRED=unknown`:
  ```bash
  gh api repos/<REPO_SLUG>/actions/workflows \
    --jq '[.workflows[] | select(.state=="active")] | length'
  ```
  - If count > 0 → **STOP** with the same message as `CI_REQUIRED=true`.
  - If count == 0 → no CI configured; proceed to Step 9.

**8c. Wait for all checks to complete:**
```bash
gh pr checks <PR_NUMBER> --repo <REPO_SLUG> --watch
```

**8d. After `--watch` exits, verify final state:**
```bash
gh pr checks <PR_NUMBER> --repo <REPO_SLUG>
```

If **ANY** check is not in a pass / success / ✓ state → **STOP**. Report the failed
check name and logs. Ask the user: "Check `<name>` failed. Fix and re-push, or
force-merge?"

Only proceed to Step 9 when **ALL** reported checks are passing.

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
)" <DELETE_BRANCH_FLAG>
```

Resolve `<DELETE_BRANCH_FLAG>` as follows before running the command:
- If `PURGE_RELEASE_BRANCH=true` AND `PRESERVE_REMOTE_BRANCH=false` → use `--delete-branch`
- Otherwise → use `--delete-branch=false`

Never use `--delete-branch` when `PRESERVE_REMOTE_BRANCH=true`, regardless of
`PURGE_RELEASE_BRANCH`. Active CI workflows must be able to complete before any
remote branch is removed.

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

## Step 11: Clean Up Release Branch

Choose the cleanup path from `PURGE_RELEASE_BRANCH` **and** `PRESERVE_REMOTE_BRANCH`:

- If `PURGE_RELEASE_BRANCH=true` and `PRESERVE_REMOTE_BRANCH=false`: purge the merged `feature/*` branch from both remote and local automatically. Do **not** ask for confirmation.
- If `PURGE_RELEASE_BRANCH=true` and `PRESERVE_REMOTE_BRANCH=true`: delete the local branch only. Never touch the remote — CI owns cleanup.
- If `PURGE_RELEASE_BRANCH=false`: keep the previous conservative behavior — only offer optional local deletion for `feature/*` branches, and do not force remote deletion.

### Template-style repositories (`PURGE_RELEASE_BRANCH=true`)

**First, check `PRESERVE_REMOTE_BRANCH`** before any deletion.

#### When `PRESERVE_REMOTE_BRANCH=true` (CI workflows are active)

Remote branch deletion is forbidden. Only delete the local branch:

```bash
if git show-ref --verify --quiet "refs/heads/<BRANCH>"; then
  git branch -D "<BRANCH>"
fi
```

The remote branch will be cleaned up by CI (e.g. `pr-merge-tagging.yml`) after it
completes. Do not delete it manually.

Success condition: `git branch --list "<BRANCH>"` returns nothing (local only).

#### When `PRESERVE_REMOTE_BRANCH=false` (no active CI workflows)

Delete from both remote and local automatically. Do **not** ask for confirmation.

```bash
git fetch origin --prune

if git ls-remote --exit-code --heads origin "<BRANCH>" >/dev/null 2>&1; then
  git push origin --delete "<BRANCH>"
fi

if git show-ref --verify --quiet "refs/heads/<BRANCH>"; then
  git branch -D "<BRANCH>"
fi

git fetch origin --prune
git branch --list "<BRANCH>"
git branch -r --list "origin/<BRANCH>"
```

Success condition:
- `git branch --list "<BRANCH>"` returns nothing
- `git branch -r --list "origin/<BRANCH>"` returns nothing

### Non-template repositories (`PURGE_RELEASE_BRANCH=false`)

Only delete if branch type is `feature` (hotfix branches are tracked by tronador).
Ask user: "Delete local branch `<BRANCH>`?"

If yes:
```bash
git branch -d "<BRANCH>"
```

---

## Step 12: Tag and Publish (Local-Publish Repositories Only)

Tag and publish via `make` is only applicable when `PUBLISH_MODE=local`. The
shared target names remain `make gitflow/version/tag gitflow/version/publish`
even when the repository's GitVersion branching model is GitHubFlow.

Decision rule:
- If `PUBLISH_MODE=ci` → skip this entire step and proceed to Step 15. CI owns tag + release after merge.
- If `PUBLISH_MODE=local` → run both targets below.

If `PUBLISH_MODE=local`, run:

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

## Step 13: Build Changelog (Local-Publish Repositories Only)

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

## Step 14: Create or Update GitHub Release (Local-Publish Repositories Only)

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
- Version:  <PREV_VERSION> → <NEW_TAG or pending CI tag>
- Publish:  <release URL or "GitHub Actions after merge">
```

---

## Rules and Edge Cases

- **Never push directly to master.** Always use a branch.
- **Never squash or rebase on merge.** Always `--merge`.
- **`+semver:` annotation must be in the body of the merge commit**, not just the title, for GitVersion to pick it up.
- **`make gitflow/version/file` may create its own version-bump commit.** After it runs, inspect `git status` / `git log` before adding more commits.
- **`make gitflow/hotfix/start` auto-names the branch** with the bumped patch version. Capture the branch name after running it.
- **Release "already exists" is normal** — CI workflows often auto-create a release from the tag push. Use `gh release edit` only when `PUBLISH_MODE=local` and you are the release publisher.
- **Never delete the remote branch when `PRESERVE_REMOTE_BRANCH=true`** — when `PUBLISH_MODE=ci` (e.g. `pr-merge-tagging.yml` or `release-management.yml` is present and active), the remote branch must remain intact until CI completes. Never pass `--delete-branch` to `gh pr merge` and never run `git push origin --delete` in this case. Only delete the local branch. CI is responsible for any remote cleanup it requires.
- **If `gh pr checks` or `statusCheckRollup` reports no checks** — this is ambiguous: checks may not have registered yet. Always complete Step 8a–8b (60-second poll + CI presence check) before concluding CI is absent. Never interpret "no checks" as "no CI" without evidence.
- **Git lock files** (`.git/index.lock`): if encountered, run `rm -f .git/index.lock` before retrying.
- **Stale hotfix branches**: if `make gitflow/hotfix/start` fails with a branch-exists error, check with `git branch -a | grep hotfix` and delete stale ones with `git branch -D hotfix/<version>`.
- **Never use `--no-verify`** on commits or pushes.
- **Uncommitted changes must become a conventional commit before release actions continue.** Do not push, open a PR, merge, tag, or publish while relevant release changes remain uncommitted.
- **If repo-local policy requires commit trailers** (for example Lore-style
  decision-record trailers), preserve them in addition to the conventional
  commit subject and semver annotation.
- **`fix/` branches** are not first-class GitVersion branches in either bundled config and are not natively supported by tronador gitflow targets. Prefer `feature/*` by default, and use `hotfix/*` only when the detected flow and repo automation support it.
- **GitVersion flow detection** (Step 0):
  - Read `.cloudopsworks/gitversion.yaml` first.
  - If the file is missing, assume `RELEASE_FLOW=gitflow`.
  - If the config contains `develop:` or `hotfix:` or `support:` branches, treat it as GitFlow.
  - If the config has `main` + `release` + `feature` + `pull-request` and no `develop:`, treat it as GitHubFlow.
  - Flow detection controls branch choice and semver interpretation, **not** the shared `make gitflow/...` target names.
- **Repo-local release policy overrides generic heuristics** (Step 0 / Steps 6, 12-14):
  - If `AGENTS.md` says GitHub Actions handle releases, set `PUBLISH_MODE=ci` and skip local release creation.
  - If `AGENTS.md` explicitly requires `make gitflow/version/file` before a PR, do it even when the repo is not a Terraform template.
  - Use `IS_TEMPLATE` only as a fallback signal; it must not override explicit repo-local policy.
- **GitHubFlow semver note**: some repos intentionally map `+semver: breaking` to MINOR. Always trust the repo's actual `major-version-bump-message` / `minor-version-bump-message` config over generic assumptions.
