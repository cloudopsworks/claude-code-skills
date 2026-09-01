---
name: cw-release
version: 1.3.2
description: |
  CloudOps Works release workflow. Detects the repository GitVersion flow and
  repo-local release policy, preserves CI-owned post-merge release automation,
  stays portable across Claude Code, Codex, and OpenCode, and then drives the
  permitted tronador make/gh release path.
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

## Exclusive CI Release Ownership

For implementation repositories, post-merge release automation is an exclusive
owner. When an active workflow can perform release management — especially a
GoReleaser path for Go or Rust — the agent must only observe it. Never race,
supplement, repair, rerun, cancel, tag, publish, edit releases, upload assets, or
clean branches for that release. A delayed, failed, cancelled, or incomplete
workflow remains CI-owned and is reported as-is; it never authorizes a local
fallback.

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
  merge, or publish behavior, follow those rules for any CloudOps Works managed
  repository family. This keeps Claude Code, Codex, and generated OpenCode
  commands aligned on the same release behavior.

---

## Step 0: Environment Check

```bash
git remote -v
git branch --show-current
git status --short
cat .cloudopsworks/_VERSION 2>/dev/null || cat .github/_VERSION 2>/dev/null || echo "NO_VERSION_FILE"
git fetch origin --tags --prune
git tag --sort=-v:refname | head -3
git log --oneline -5
```

Verify:
- We are in a git repository with a valid remote.
- The current branch is `master` (or `main`). If not, **STOP** and ask the user if they want to continue from a non-master branch.
- Capture: `CURRENT_VERSION` (from `_VERSION` file or latest tag), `REPO_SLUG` (from remote URL, e.g. `cloudopsworks/go-app-template`), `MAIN_BRANCH` (`master` or `main`).

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

**Detect repository template and version-file authority** — run:
```bash
ls .cloudopsworks/_VERSION .github/_VERSION 2>/dev/null
gh repo view <REPO_SLUG> --json isTemplate 2>/dev/null || echo '{"isTemplate":null}'
sed -n '1,260p' AGENTS.md 2>/dev/null || true
```

Set `GH_IS_TEMPLATE` from GitHub:
- `true` when `gh repo view` reports `"isTemplate": true`.
- `false` when `gh repo view` reports `"isTemplate": false`.
- `unknown` when `gh` is unavailable, unauthenticated, or returns `null`.

Do **not** infer template status from technology-specific marker files or the
absence of those files. CloudOps Works manages many template families, and the
GitHub template flag is the default authority.

Set `LOCAL_VERSION_FILE_POLICY` from `AGENTS.md`:
- `managed` when repo-local instructions explicitly require or allow updating
  `.cloudopsworks/_VERSION` / `.github/_VERSION`, require
  `make gitflow/version/file` before the PR, or otherwise state that this
  repository owns its version file on the working branch.
- `protected` when repo-local instructions explicitly say not to write, stage,
  commit, or release `_VERSION` files from this repository.
- `unspecified` when `AGENTS.md` is silent.

Set `VERSION_FILE_WRITABLE`:
- `false` when `LOCAL_VERSION_FILE_POLICY=protected`.
- `true` when `GH_IS_TEMPLATE=true`.
- `true` when `LOCAL_VERSION_FILE_POLICY=managed` (the explicit local-policy
  exception for non-template repositories).
- `false` otherwise. When GitHub says `isTemplate=false`, or when GitHub status
  is unknown, `_VERSION` is protected unless `AGENTS.md` explicitly directs
  different behavior.

Set `IS_TEMPLATE` for template workflow policy:
- `true` when `GH_IS_TEMPLATE=true`.
- `true` only when `AGENTS.md` explicitly states this repository is a CloudOps
  Works template/source repository whose template workflows are edited locally.
- `false` otherwise. Do not use legacy implementation heuristics.

Capture: `GH_IS_TEMPLATE` (`true` / `false` / `unknown`),
`LOCAL_VERSION_FILE_POLICY` (`managed` / `protected` / `unspecified`),
`VERSION_FILE_WRITABLE` (`true` / `false`), and `IS_TEMPLATE`
(`true` / `false`). Do **not** use `IS_TEMPLATE` alone to decide publish
behavior.

**Detect repo-local release policy and CI release ownership** — run:
```bash
sed -n '1,260p' AGENTS.md 2>/dev/null || true
ls .github/workflows/pr-merge-tagging.yml .github/workflows/release-management.yml 2>/dev/null || true

# Inspect every workflow and release configuration, not only conventionally
# named release workflows. Implementation repositories often publish from a
# main-build workflow after the PR merge.
find .github/workflows -maxdepth 1 -type f \
  \( -name '*.yml' -o -name '*.yaml' \) -print 2>/dev/null | sort
grep -RInE \
  'goreleaser|release-plz|cargo[[:space:]]+(publish|dist)|gh[[:space:]]+release|softprops/action-gh-release|gitflow/version/(tag|publish)|release-management|create[^[:alnum:]]+release|upload[^[:alnum:]]+release' \
  .github/workflows .cloudopsworks 2>/dev/null || true
grep -RInE '(^|[[:space:]])goreleaser:[[:space:]]*true([[:space:]]|$)' \
  .cloudopsworks .github 2>/dev/null || true
gh workflow list --repo <REPO_SLUG> --all \
  --json id,name,path,state 2>/dev/null || true
```

**Detect version-file maintenance from git history, not from prose.** Documentation can
omit a step the repository has in fact always performed. Ask the history whether this repo
maintains its version file:

```bash
VERSION_PATH=$(ls .cloudopsworks/_VERSION .github/_VERSION 2>/dev/null | head -1)
if [ -n "$VERSION_PATH" ]; then
  echo "VERSION_PATH=$VERSION_PATH"
  echo "BUMP_COMMITS=$(git log --oneline -- "$VERSION_PATH" | wc -l | tr -d ' ')"
  printf 'FILE_VALUE=%s\nLATEST_TAG=%s\n' \
    "$(cat "$VERSION_PATH")" "$(git tag --sort=-v:refname | head -1)"
else
  echo "NO_VERSION_FILE"
fi
```

Set the following policy flags:
- `RUN_VERSION_FILE_BEFORE_PR=true` when repo-local instructions explicitly require
  `make gitflow/version/file` before the PR, **or** when `BUMP_COMMITS` is greater than zero
  (the repository has a history of bumping its version file, which is authoritative evidence
  that it maintains one). This flag can only cause a write when `VERSION_FILE_WRITABLE=true`.
- A version file that trails `LATEST_TAG` is **drift to be repaired, never policy to be
  matched.** Prior releases skipping the bump is a defect in those releases. Never reason
  "the last N releases left it stale, so I will too" — set `RUN_VERSION_FILE_BEFORE_PR=true`
  and let this release self-heal the file. Report the drift to the user.
- Set `CI_RELEASE_OWNER_DETECTED=true` for an implementation repository when any
  active workflow or repo-local release configuration can tag, publish, create a
  release, or invoke a release tool after merge. This includes GoReleaser for
  Go **or Rust**, even when it is invoked indirectly from `main-build.yml`, a
  reusable workflow, or a CloudOps Works configuration flag rather than from a
  file named `release-management.yml`.
- `PUBLISH_MODE=ci` when repo-local instructions say releases are handled by
  GitHub Actions **or** when `CI_RELEASE_OWNER_DETECTED=true`.
- Detection is fail-closed for implementation repositories: if an active
  post-merge build/release workflow or an enabled GoReleaser configuration could
  own publication, choose `PUBLISH_MODE=ci`. Do not choose local publication
  merely because a workflow has an unfamiliar name or because the release job
  has not started yet.
- `PUBLISH_MODE=local` only when no CI release owner is detected and repository
  policy or established release mechanics positively assign tag + release
  publication to the operator.

**Template repository override:** After computing `PUBLISH_MODE` from workflow files, if
`GH_IS_TEMPLATE=true` → unconditionally override to `PUBLISH_MODE=local`. GitHub
disables Actions on template repositories; `pr-merge-tagging.yml`,
`release-management.yml`, and any other workflows will never execute even when present
in `.github/workflows/`. Tags and GitHub releases must always be created locally for
template repos — CI will never do it regardless of what workflow files exist.

Capture: `RUN_VERSION_FILE_BEFORE_PR` (`true` / `false`),
`CI_RELEASE_OWNER_DETECTED` (`true` / `false`), the matching
`CI_RELEASE_WORKFLOWS`, and `PUBLISH_MODE` (`ci` / `local`). These control the
post-merge observer gate and Steps 6 and 12-14.

Detect CI requirement from AGENTS.md content:
- `CI_REQUIRED=true` when AGENTS.md contains phrases like "wait for checks", "checks must
  pass", "CI required", "do not merge until checks", or when `PUBLISH_MODE=ci`.
- `CI_REQUIRED=false` when AGENTS.md explicitly says "no CI", "no checks", or the repo has
  no `.github/workflows/` directory.
- `CI_REQUIRED=false` when `GH_IS_TEMPLATE=true` — GitHub template repositories have
  Actions disabled by default; checks will never register on feature PRs regardless of
  what workflows are present in `.github/workflows/`. Do not poll; proceed directly to
  merge after the PR is created.
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

## Step 1.5: Workflow Safety Guard

Run immediately after Step 1. Enforce repository-type policies before any branch,
commit, or push action proceeds. Violations **always** result in a STOP with
`AskUserQuestion` — never auto-fix or silently skip a guard without explicit user
clearance.

---

### Guard 4 — Protected repository: `_VERSION` file protection

**Applies when:** `VERSION_FILE_WRITABLE=false`.

**This guard runs unconditionally** — it is not gated on workflow file changes.
The `.cloudopsworks/_VERSION` and `.github/_VERSION` files are writable only for
GitHub template repositories (`GH_IS_TEMPLATE=true`) or for repositories whose
local `AGENTS.md` explicitly declares that this repository owns version-file
updates. Otherwise they are protected and must not be committed, staged, or
released from this repository.

```bash
VERSION_IN_DIFF=$(git diff HEAD --name-only 2>/dev/null \
  | grep -E '(\.cloudopsworks/_VERSION|\.github/_VERSION)' || true)
VERSION_UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null \
  | grep -E '(\.cloudopsworks/_VERSION|\.github/_VERSION)' || true)
ALL_VERSION_FILES=$(printf '%s\n%s' "$VERSION_IN_DIFF" "$VERSION_UNTRACKED" \
  | grep -v '^$' | sort -u || true)
echo "VERSION_FILES_IN_DIFF: $ALL_VERSION_FILES"
```

**If `VERSION_FILE_WRITABLE=true` OR `ALL_VERSION_FILES` is empty — skip Guard 4 and continue.**

If `VERSION_FILE_WRITABLE=false` AND `ALL_VERSION_FILES` is non-empty, **STOP.**
This guard is a hard block. Immediately revert the `_VERSION` file(s) without asking:

```bash
for vf in $ALL_VERSION_FILES; do
  git checkout HEAD -- "$vf" 2>/dev/null || git rm --cached "$vf" 2>/dev/null || true
done
```

Then use `AskUserQuestion` to inform the user:

State:
- The project slug and current branch.
- That this repository is **not authorized to write `_VERSION`** because GitHub
  does not identify it as a template repository and local `AGENTS.md` does not
  explicitly override that default protection.
- The list of files that were reverted.
- That version file updates must originate from the template/source repository's
  release workflow, or from an explicit repo-local `AGENTS.md` policy that
  authorizes this repository to update `_VERSION`.

Options:
- A) Continue the release without the `_VERSION` change (file has been reverted)
- B) Abort the release — this repository should not update `_VERSION` this way

If the user chooses A: continue to the workflow file checks below.
If the user chooses B: **STOP** the entire release workflow. Do not proceed.

---

Now detect workflow file changes for Guards 1–3:

```bash
CHANGED_WORKFLOWS=$(git diff HEAD --name-only 2>/dev/null \
  | grep -E '\.github/workflows/.*\.(yml|yaml)$' || true)
ADDED_WORKFLOWS=$(git ls-files --others --exclude-standard 2>/dev/null \
  | grep -E '\.github/workflows/.*\.(yml|yaml)$' || true)
ALL_CHANGED_WORKFLOWS=$(printf '%s\n%s' "$CHANGED_WORKFLOWS" "$ADDED_WORKFLOWS" \
  | grep -v '^$' | sort -u || true)
echo "CHANGED_WORKFLOWS:"
echo "$ALL_CHANGED_WORKFLOWS"
```

**If `ALL_CHANGED_WORKFLOWS` is empty — skip Guards 1–3 and continue to Step 2.**

---

### Guard 1 — Non-template repository: workflow file protection

**Applies when:** `IS_TEMPLATE=false` AND `ALL_CHANGED_WORKFLOWS` is non-empty.

**This guard is a hard block. There is no clearance path and no bypass option.**
Workflow files in non-template repositories are normally owned by upstream
templates or repo-local maintainers, not by a generic release pass.
The agent must not commit, push, or release them under any circumstance.

**STOP.** Immediately revert the workflow files without asking:

```bash
git checkout HEAD -- $ALL_CHANGED_WORKFLOWS
```

Then use `AskUserQuestion` to inform the user:

State:
- The project slug and current branch.
- That this is **not a template repository** under the detected policy —
  workflow files under `.github/workflows/` have been automatically reverted.
- The list of files that were reverted.
- That if this change is genuinely required, it must go through the upstream
  template/source repository, or the local `AGENTS.md` must explicitly say this
  repository owns workflow edits.

Options:
- A) Continue the release without the workflow changes (files have been reverted)
- B) Abort the release — I will handle the workflow change through the template/source policy first

If the user chooses A: continue to Step 2 (workflow files no longer in scope; skip Guard 2 and Guard 3).
If the user chooses B: **STOP** the entire release workflow. Do not proceed.

---

### Guard 2 — Template repository: blueprint and local action version references

**Applies when:** `IS_TEMPLATE=true` AND `ALL_CHANGED_WORKFLOWS` is non-empty.

Scan every changed workflow file for `uses:` entries that reference
`cloudopsworks/blueprints` or `./bp` actions pinned with a full three-part semver
(`@vX.Y.Z`). The required format for these references is `@vX.Y` (major.minor only —
no patch segment).

```bash
BLUEPRINT_VIOLATIONS=""
for wf in $ALL_CHANGED_WORKFLOWS; do
  [ -f "$wf" ] || continue
  MATCHES=$(grep -n 'uses:' "$wf" \
    | grep -E '(cloudopsworks/blueprints|\.\/bp)' \
    | grep -E '@v[0-9]+\.[0-9]+\.[0-9]+' 2>/dev/null || true)
  [ -n "$MATCHES" ] && BLUEPRINT_VIOLATIONS="${BLUEPRINT_VIOLATIONS}  [${wf}]
${MATCHES}
"
done
printf '%s\n' "BLUEPRINT_VIOLATIONS:${BLUEPRINT_VIOLATIONS}"
```

**If `BLUEPRINT_VIOLATIONS` is empty — skip Guard 2 and proceed to Guard 3.**

If violations are found, **STOP.** Use `AskUserQuestion`:

State:
- The project slug, current branch, and each violation (file path, line number, and offending `uses:` value).
- That template workflow files must pin `cloudopsworks/blueprints` and `./bp` actions with `@vX.Y` (major.minor), not full semver `@vX.Y.Z`.
- Correct format example: `uses: cloudopsworks/blueprints/.github/actions/my-action@v5.10`

Options:
- A) Auto-correct — strip the patch segment from all flagged blueprint/bp references now
- B) Proceed with clearance — I confirm these pinned versions are intentional

If the user chooses A: for each flagged `uses:` line use the `Edit` tool to replace
`@vX.Y.Z` with `@vX.Y` (keep major and minor, remove the `.Z` patch segment).
Confirm each edit. Set `GUARD_2_AUTOCORRECTED=true`. Proceed to Guard 3.

If the user chooses B: set `WORKFLOW_GUARD_2_CLEARED=true`. Proceed to Guard 3.

---

### Guard 3 — Template repository: all other action version references

**Applies when:** `IS_TEMPLATE=true` AND `ALL_CHANGED_WORKFLOWS` is non-empty.

Scan every changed workflow file for `uses:` entries referencing any action that is
**not** `cloudopsworks/blueprints` or `./bp` and that uses more than a major-only
version pin. The required format for all other external actions is `@vX` (major only).
Any `@vX.Y`, `@vX.Y.Z`, or deeper pin is a violation.

```bash
OTHER_VIOLATIONS=""
for wf in $ALL_CHANGED_WORKFLOWS; do
  [ -f "$wf" ] || continue
  MATCHES=$(grep -n 'uses:' "$wf" \
    | grep -Ev '(cloudopsworks/blueprints|\.\/bp)' \
    | grep -E '@v[0-9]+\.[0-9]+' 2>/dev/null || true)
  [ -n "$MATCHES" ] && OTHER_VIOLATIONS="${OTHER_VIOLATIONS}  [${wf}]
${MATCHES}
"
done
printf '%s\n' "OTHER_VIOLATIONS:${OTHER_VIOLATIONS}"
```

**If `OTHER_VIOLATIONS` is empty — skip Guard 3 and continue to Step 2.**

If violations are found, **STOP.** Use `AskUserQuestion`:

State:
- The project slug, current branch, and each violation (file path, line number, and offending `uses:` value).
- That template workflow files must reference external actions with major-only version pins (`@vX`), not `@vX.Y` or `@vX.Y.Z`.
- Correct format examples: `uses: actions/checkout@v4`, `uses: hashicorp/setup-terraform@v3`

Options:
- A) Auto-correct — strip minor/patch segments from all flagged external action references now
- B) Proceed with clearance — I confirm these pinned versions are intentional

If the user chooses A: for each flagged `uses:` line use the `Edit` tool to replace
`@vX.Y.Z` or `@vX.Y` with `@vX` (keep major only, remove `.Y.Z` or `.Y`).
Confirm each edit. Set `GUARD_3_AUTOCORRECTED=true`. Continue to Step 2.

If the user chooses B: set `WORKFLOW_GUARD_3_CLEARED=true`. Continue to Step 2.

---

After all applicable guards are resolved (or skipped as non-applicable), continue to Step 2.

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
`.env`, credentials, or generated files unless they are `_CHANGELOG`, or `_VERSION`
**only when `VERSION_FILE_WRITABLE=true`** — never stage
`.cloudopsworks/_VERSION` or `.github/_VERSION` when version-file protection is
active.

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
- **GUARD (hard block, no bypass):** If `VERSION_FILE_WRITABLE=false` → **skip this
  step entirely.** `_VERSION` files must never be written unless GitHub reports
  `isTemplate=true` or local `AGENTS.md` explicitly authorizes this repository to
  update its version file. Proceed directly to the read-only path below and then
  continue to Step 7.
- If `VERSION_FILE_WRITABLE=true` AND `RUN_VERSION_FILE_BEFORE_PR=true` → run this step.
- If `VERSION_FILE_WRITABLE=true` AND `RUN_VERSION_FILE_BEFORE_PR=false` → **run this step
  anyway** unless the repository has no version file at all (`NO_VERSION_FILE`) or its
  `AGENTS.md` contains an explicit written statement that the version file is not bumped on
  release. Running is the default when the file exists and is writable; skipping requires
  positive evidence, not merely the absence of an instruction to run.

**Never infer "skip" from any of the following** — each is a symptom of the bug this step
exists to prevent, not a policy signal:
- The version file is stale relative to the latest tag.
- Recent releases did not bump it.
- `AGENTS.md` does not mention `gitflow/version/file` in its numbered workflow.

When the file exists, is writable, and this branch will produce a release, the bump runs.

**Ordering:** run this step after Step 5 (branch pushed) and before any pre-release tag, so
the `chore: Version Bump` commit is covered by that tag and the release gate's
"no untested commits after the last tag" check stays satisfiable.

If skipping, read the current version file (when present) to capture `CURRENT_VERSION`:
```bash
cat .cloudopsworks/_VERSION 2>/dev/null || cat .github/_VERSION 2>/dev/null || true
```

If running, execute:
```bash
git fetch origin --tags --prune
make gitflow/version/file
```

Capture the new version from the output or by reading the version file:
```bash
cat .cloudopsworks/_VERSION 2>/dev/null || cat .github/_VERSION 2>/dev/null
```

Capture: `NEW_VERSION` (e.g. `v1.7.0`).

Verify the version did not regress against fetched remote tags:
```bash
LATEST_TAG=$(git tag --sort=-v:refname | head -1)
NEW_VERSION=$(cat .cloudopsworks/_VERSION 2>/dev/null || cat .github/_VERSION 2>/dev/null)
printf 'LATEST_TAG=%s\nNEW_VERSION=%s\n' "$LATEST_TAG" "$NEW_VERSION"
```

**STOP** if `NEW_VERSION` is lower than the latest remote tag or if it equals an
already-published release while this release should create a new tag. Fetch tags
again and recalculate before continuing.

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
gh pr view <PR_NUMBER> --repo <REPO_SLUG> --json state,mergedAt,mergeCommit
```

Confirm `"state":"MERGED"` and capture `MERGE_SHA` from
`.mergeCommit.oid`.

---

## Step 9.5: Observe CI-Owned Post-Merge Release Automation

This is a mandatory ownership boundary for implementation repositories.

If `GH_IS_TEMPLATE=true` and `PUBLISH_MODE=local`, skip this step and continue
to Step 10.

For every implementation repository, perform one final read-only ownership
check after merge and before any local version/tag/release command. Re-run the
Step 0 release-signal scan and list runs for `MERGE_SHA`. If a matching workflow
is active, a post-merge run exposes release/publish/GoReleaser jobs, or ownership
is ambiguous, set `CI_RELEASE_OWNER_DETECTED=true` and
`PUBLISH_MODE=ci`. This late check prevents a workflow that registered only
after merge from being mistaken for absence of CI ownership.

Only an implementation repository with positive evidence of local publication
and no static or running CI release owner may keep `PUBLISH_MODE=local` and skip
the remainder of this step.

If `PUBLISH_MODE=ci`, immediately enter **release observer mode** after the PR
merge. From this point through workflow completion, use read-only observation
only. The release workflow is the sole owner of version calculation, tags,
artifacts, GoReleaser (Go or Rust), package publication, and GitHub Releases.

Permitted commands in release observer mode:

- `gh run list`
- `gh run view`
- `gh run watch --exit-status`
- `gh pr view`
- `gh release view` / `gh release list`
- read-only `git fetch`, `git log`, `git show`, and `git tag --list`

Forbidden commands and actions in release observer mode:

- Do not run `make gitflow/version/file`, `make gitflow/version/tag`,
  `make gitflow/version/publish`, GoReleaser, Cargo release/publish commands, or
  any equivalent release command.
- Do not create, move, force, delete, or push tags.
- Do not create, edit, publish, delete, or upload assets to a GitHub Release.
- Do not trigger, rerun, cancel, approve, or dispatch workflows or jobs.
- Do not push commits, amend version files, repair generated changelogs, or
  delete local or remote release branches.
- Do not fall back to local publication when the workflow is delayed, waiting
  for an environment, fails, is cancelled, or produces no tag/release.

Poll for post-merge workflow registration by the exact merge commit. Ignore PR
event runs because those belong to the pre-merge gate:

```bash
COUNT=0
for i in $(seq 1 12); do
  COUNT=$(gh run list --repo <REPO_SLUG> --commit <MERGE_SHA> --limit 100 \
    --json event \
    --jq '[.[] | select(.event != "pull_request" and .event != "pull_request_target")] | length')
  [ "$COUNT" -gt 0 ] && break
  echo "No post-merge runs yet (attempt $i/12). Waiting 10s..."
  sleep 10
done
gh run list --repo <REPO_SLUG> --commit <MERGE_SHA> --limit 100 \
  --json databaseId,name,workflowName,event,status,conclusion,headSha,url,createdAt \
  --jq '.[] | select(.event != "pull_request" and .event != "pull_request_target")'
```

If no post-merge run appears after 120 seconds, **STOP** and report that the
CI-owned release did not register. Do not tag or publish locally.

Watch every post-merge run associated with `MERGE_SHA`. Re-list after each
completion because release workflows may start reusable or `workflow_run`
children only after an earlier build finishes:

```bash
QUIET_POLLS=0
while :; do
  PENDING_IDS=$(gh run list --repo <REPO_SLUG> --commit <MERGE_SHA> --limit 100 \
    --json databaseId,event,status \
    --jq '.[] | select(.event != "pull_request" and .event != "pull_request_target" and .status != "completed") | .databaseId')
  for run_id in $PENDING_IDS; do
    gh run watch "$run_id" --repo <REPO_SLUG> --exit-status || true
  done
  ACTIVE=$(gh run list --repo <REPO_SLUG> --commit <MERGE_SHA> --limit 100 \
    --json event,status \
    --jq '[.[] | select(.event != "pull_request" and .event != "pull_request_target" and .status != "completed")] | length')
  CURRENT_IDS=$(gh run list --repo <REPO_SLUG> --commit <MERGE_SHA> --limit 100 \
    --json databaseId,event \
    --jq '[.[] | select(.event != "pull_request" and .event != "pull_request_target") | .databaseId] | sort | join(",")')
  if [ "$ACTIVE" -ne 0 ]; then
    QUIET_POLLS=0
    continue
  fi
  sleep 15
  REFRESHED_ACTIVE=$(gh run list --repo <REPO_SLUG> --commit <MERGE_SHA> --limit 100 \
    --json event,status \
    --jq '[.[] | select(.event != "pull_request" and .event != "pull_request_target" and .status != "completed")] | length')
  REFRESHED_IDS=$(gh run list --repo <REPO_SLUG> --commit <MERGE_SHA> --limit 100 \
    --json databaseId,event \
    --jq '[.[] | select(.event != "pull_request" and .event != "pull_request_target") | .databaseId] | sort | join(",")')
  if [ "$REFRESHED_ACTIVE" -eq 0 ] && [ "$REFRESHED_IDS" = "$CURRENT_IDS" ]; then
    QUIET_POLLS=$((QUIET_POLLS + 1))
  else
    QUIET_POLLS=0
  fi
  [ "$QUIET_POLLS" -ge 4 ] && break
done
gh run list --repo <REPO_SLUG> --commit <MERGE_SHA> --limit 100 \
  --json databaseId,name,workflowName,event,status,conclusion,url \
  --jq '.[] | select(.event != "pull_request" and .event != "pull_request_target")'
BAD_COUNT=$(gh run list --repo <REPO_SLUG> --commit <MERGE_SHA> --limit 100 \
  --json event,conclusion \
  --jq '[.[] | select(.event != "pull_request" and .event != "pull_request_target" and .conclusion != "success" and .conclusion != "skipped" and .conclusion != "neutral")] | length')
```

If any observed run concludes as `failure`, `cancelled`, `timed_out`,
`action_required`, or another non-success terminal state, **STOP** and report
the run URL and conclusion. Do not rerun it or perform any release mutation.

When all post-merge runs succeed or are legitimately skipped, inspect the
resulting tag/release read-only and continue to Step 10. CI remains the release
owner even after its run completes; Steps 12-14 stay forbidden.

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

- If `PUBLISH_MODE=ci`: skip branch cleanup entirely. Keep both local and remote
  branches untouched. A CI-owned post-merge release may retain branch context
  for attribution, delayed jobs, GoReleaser, or follow-up automation. Observers
  never decide when that context is safe to remove.
- If `PURGE_RELEASE_BRANCH=true` and `PRESERVE_REMOTE_BRANCH=false`: purge the merged `feature/*` branch from both remote and local automatically. Do **not** ask for confirmation.
- If `PURGE_RELEASE_BRANCH=false`: keep the previous conservative behavior — only offer optional local deletion for `feature/*` branches, and do not force remote deletion.

### Template-style repositories (`PUBLISH_MODE=local` and `PURGE_RELEASE_BRANCH=true`)

**First, check `PRESERVE_REMOTE_BRANCH`** before any deletion.

#### When `PRESERVE_REMOTE_BRANCH=true` (CI owns release automation)

Do not delete either branch. Do not pass a branch deletion flag during merge,
and do not run local or remote deletion commands after merge. Report the branch
as retained for CI ownership.

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

### Non-template repositories (`PUBLISH_MODE=local` and `PURGE_RELEASE_BRANCH=false`)

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
- If `PUBLISH_MODE=ci` → skip this entire step and proceed to Step 15. CI owns
  tag + release after merge. This is an absolute ownership boundary, not a race:
  never run local tagging/publication even if CI is slow, fails, is cancelled,
  waits for approval, or has not produced a tag or release yet.
- If `PUBLISH_MODE=local` → run both targets below.

If `PUBLISH_MODE=local`, run:

```bash
git fetch origin --tags --prune
make gitflow/version/tag gitflow/version/publish
```

Capture the tag name from output (e.g. `Tagged v1.7.0...`). Confirm:
```bash
git tag --sort=-v:refname | head -3
```

**STOP** if tagging fails with "must be in the latest commit of the branch". This means
remote is ahead — run `git pull origin <MAIN_BRANCH>` and retry.

**If `make` exits non-zero with "already exists"** in a positively identified
local-publish repository, stop mutating and verify read-only whether an external
publisher created the tag:
```bash
git fetch --tags && git tag --sort=-v:refname | head -3
```
Do not race that publisher or overwrite its output. Reclassify the repository as
`PUBLISH_MODE=ci`, enter release observer mode, and skip Steps 13-14.

> **Note:** `make gitflow/version/publish` guarantees the git tag is pushed to the
> remote. It does **not** guarantee a GitHub release is created — tronador's publish
> target behaviour varies by repo. Always proceed through Steps 13–14 to build the
> changelog and create the GitHub release. Step 14 checks for an existing release
> and fails closed to read-only observer mode rather than editing another publisher's
> output.

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

## Step 14: Create GitHub Release (Local-Publish Repositories Only)

First check if the release already exists:

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

**If EXISTS:** do not edit it. An existing release is evidence that another
publisher may own the release even if Step 0 missed it. Reclassify as
`PUBLISH_MODE=ci`, inspect the release and matching workflow runs read-only,
and report the ownership conflict. Never overwrite a CI-created release body or
assets.

Output the release URL.

---

## Step 15: Verify Invariants and Summarize

For `PUBLISH_MODE=local`, verify the version-file invariant. Skip only when the
repo reported `NO_VERSION_FILE` or `VERSION_FILE_WRITABLE=false`:

```bash
git fetch origin --tags --prune
VERSION_PATH=$(ls .cloudopsworks/_VERSION .github/_VERSION 2>/dev/null | head -1)
printf 'file=%s tag=%s\n' "$(cat "$VERSION_PATH")" "$(git tag --sort=-v:refname | head -1)"
```

The two values must be equal. If they disagree, **say so explicitly in the
summary** — do not report a clean release over a broken invariant. Never
hand-edit the file to force agreement; the correct repair is a follow-up release
that runs Step 6.

For `PUBLISH_MODE=ci`, verification stays read-only and reports observed facts
rather than enforcing a local publisher's invariant:

```bash
git fetch origin --tags --prune
gh run list --repo <REPO_SLUG> --commit <MERGE_SHA> --limit 100 \
  --json databaseId,name,workflowName,event,status,conclusion,url
gh release list --repo <REPO_SLUG> --limit 10
git tag --sort=-v:refname | head -3
```

Do not create or repair anything when expected CI output is absent. Report the
workflow state, observed tag/release (or `pending` / `missing`), and workflow
URLs. A failed or incomplete CI-owned release is not a local-release fallback.

Then print a concise summary:

```
## Release Complete

- Branch:   <BRANCH>
- PR:       #<PR_NUMBER>  (<URL>)
- Version:  <PREV_VERSION> → <NEW_TAG or pending/missing CI tag>
- _VERSION: <file value>  (matches tag / MISMATCH / protected / CI-owned)
- Publish:  <release URL or CI workflow state + URL>
```

---

## Rules and Edge Cases

- **Never push directly to master.** Always use a branch.
- **Never squash or rebase on merge.** Always `--merge`.
- **`+semver:` annotation must be in the body of the merge commit**, not just the title, for GitVersion to pick it up.
- **`make gitflow/version/file` may create its own version-bump commit.** After it runs, inspect `git status` / `git log` before adding more commits.
- **`make gitflow/hotfix/start` auto-names the branch** with the bumped patch version. Capture the branch name after running it.
- **CI release ownership is exclusive and permanent for the run.** In an
  implementation repository, once an active post-merge release owner is
  detected, the agent only observes it. Never tag, publish, edit a release,
  dispatch/rerun/cancel a workflow, change a version file, or clean up release
  branches as a fallback — before, during, or after that workflow.
- **An existing release is an ownership signal, not an edit target.** If a
  release already exists during a supposedly local publish, stop mutation,
  reclassify to CI-owned observation, and never edit its notes or assets.
- **Never delete either branch when `PRESERVE_REMOTE_BRANCH=true`.** When
  `PUBLISH_MODE=ci`, keep both local and remote branches untouched. Never pass
  `--delete-branch` to `gh pr merge`, run `git push origin --delete`, or delete
  the local branch. CI or a human owner decides later cleanup.
- **GitHub template repos always use `PUBLISH_MODE=local`** — when `GH_IS_TEMPLATE=true`, GitHub Actions are disabled and no CI workflow will ever run, even if `pr-merge-tagging.yml` or `release-management.yml` exist in `.github/workflows/`. The `PUBLISH_MODE=ci` detection from workflow file presence is overridden to `PUBLISH_MODE=local` in Step 0. Always run Steps 12–14 (tag + publish + release) for template repos.
- **`make gitflow/version/publish` only pushes the tag** — it does not create a
  GitHub release. In a positively identified local-publish repository, continue
  to Steps 13–14 and use `gh release create` only when no release exists.
- **If `gh pr checks` or `statusCheckRollup` reports no checks** — this is ambiguous: checks may not have registered yet. Always complete Step 8a–8b (60-second poll + CI presence check) before concluding CI is absent. Never interpret "no checks" as "no CI" without evidence. **Exception: when `GH_IS_TEMPLATE=true`, no checks will ever register** — GitHub disables Actions on template repositories by default. Skip the poll entirely; `CI_REQUIRED=false` for all template repos regardless of what workflows exist in `.github/workflows/`.
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
  - If `AGENTS.md` explicitly requires `make gitflow/version/file` before a PR, do it only when `VERSION_FILE_WRITABLE=true`.
  - GitHub `isTemplate=true` makes `_VERSION` writable by default for every CloudOps Works managed template family. GitHub `isTemplate=false` or unknown keeps `_VERSION` protected unless local `AGENTS.md` explicitly directs different behavior.
  - Use `IS_TEMPLATE` only for template workflow policy and branch-cleanup heuristics; it does **not** override explicit repo-local publish or version-file policy.
- **GitHubFlow semver note**: some repos intentionally map `+semver: breaking` to MINOR. Always trust the repo's actual `major-version-bump-message` / `minor-version-bump-message` config over generic assumptions.
- **A stale `_VERSION` is a defect, never a convention.** When the version file trails the latest tag, prior releases skipped Step 6. Repair it by running Step 6 on this release — never by hand-editing the file, and never by "staying consistent" with the releases that skipped it. Detect version-file maintenance from `git log -- <version-path>`, not from whether `AGENTS.md` happens to document the step.
- **`_VERSION` write protection (default for non-template repos):** `.cloudopsworks/_VERSION` and `.github/_VERSION` must never be written, staged, or committed when `VERSION_FILE_WRITABLE=false`. Step 6 (`make gitflow/version/file`) is unconditionally skipped in that state, even if `RUN_VERSION_FILE_BEFORE_PR=true`. If `_VERSION` already appears in the diff while protected, Guard 4 in Step 1.5 reverts it immediately. This check runs before any branch, commit, or push action.
- **Fetch tags before version calculation:** Run `git fetch origin --tags --prune` before any GitVersion-based `_VERSION`, tag, or publish calculation. Do not continue if the computed `_VERSION` is lower than the latest fetched remote tag.
- **Workflow Safety Guard (Step 1.5) is mandatory and never skipped** when workflow files appear in the diff. It is the primary mechanism that prevents AI agents from silently modifying workflows in non-template repos or introducing bad version pins in templates. Any bypass requires explicit user clearance via `AskUserQuestion`.
- **Non-template repos must not modify workflow files — hard block, no bypass.** If `.github/workflows/*.yml` or `.github/workflows/*.yaml` files appear in the diff for an `IS_TEMPLATE=false` repo, Guard 1 fires unconditionally, reverts the files immediately, and does not offer a "proceed anyway" path. Workflow changes must go through the upstream template/source repository, or local `AGENTS.md` must explicitly define that this repository owns workflow edits.
- **Template repos: blueprints/bp actions must use `@vX.Y` pins.** `uses:` entries referencing `cloudopsworks/blueprints` or `./bp` must carry exactly a major.minor version tag (e.g. `@v5.10`). Full three-part semver (`@v5.10.3`) is a Guard 2 violation regardless of which branch is active.
- **Template repos: all other external actions must use `@vX` (major-only) pins.** Any `uses:` entry not in the `cloudopsworks/blueprints` / `./bp` namespace must carry only a major version tag (e.g. `@v4`). `@v4.1` or `@v4.1.2` are Guard 3 violations.
- **User clearance on any guard is final for that session.** Once a guard is cleared with option B, do not re-fire it for the same workflow files in the same release run. However, if new workflow files appear (e.g. the user adds more), re-evaluate all applicable guards for the new files.
