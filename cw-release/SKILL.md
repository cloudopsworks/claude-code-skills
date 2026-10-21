---
name: cw-release
version: 1.3.2
description: |
  CloudOps Works release workflow. Detects the repository GitVersion flow and
  repo-local release policy, preserves CI-owned post-merge release automation,
  stays portable across Claude Code, Codex, and OpenCode, and then drives the
  permitted Tronador CLI/gh release path.
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
use GitFlow, GitHubFlow, or trunk-based semantics through GitVersion. Detect the
active flow from the canonical selector in `.cloudopsworks/gitversion.yaml`;
unsupported, duplicate, or contradictory metadata is unverified and must fail
closed before any branch operation. A genuinely absent config may resolve to
GitHub Flow only for the exact verified canonical CloudOps Works app-template
source exception defined in Step 0; absence remains unverified everywhere else.
Then detect any repo-local release policy from `AGENTS.md`, version
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
  If the platform names tools differently, execute the same git, gh, Tronador CLI, and
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
ORIGIN_PRIMARY=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)
API_PRIMARY=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name // empty' 2>/dev/null || true)
git tag --sort=-v:refname | head -3
git log --oneline -5
```

Verify:
- We are in a git repository with a valid remote.
- Resolve `PRIMARY_BRANCH` from the configured `origin/HEAD`, trusted GitHub API
  `defaultBranchRef.name`, and any explicit repo-local branch policy. Do not assume
  `main` or `master`. All available authoritative signals must agree; no signal or a
  conflict is ambiguous and must fail closed before branch operations.
  After reading `AGENTS.md`, set `POLICY_PRIMARY` only when it explicitly names the
  primary branch, then validate:
  ```bash
  PRIMARY_CANDIDATES=$(printf '%s\n%s\n%s\n' \
    "$ORIGIN_PRIMARY" "$API_PRIMARY" "$POLICY_PRIMARY" | grep -v '^$' | sort -u)
  PRIMARY_COUNT=$(printf '%s\n' "$PRIMARY_CANDIDATES" | grep -c . || true)
  [ "$PRIMARY_COUNT" -eq 1 ] || { echo "AMBIGUOUS_PRIMARY_BRANCH"; exit 1; }
  PRIMARY_BRANCH=$PRIMARY_CANDIDATES
  ```
- The current branch equals the verified `PRIMARY_BRANCH`. If not, **STOP** and ask
  whether to return to the configured primary branch; do not substitute a hardcoded branch.
- Capture: `CURRENT_VERSION` (from `_VERSION` file or latest tag), `REPO_SLUG`
  (from remote URL, e.g. `cloudopsworks/go-app-template`), and `PRIMARY_BRANCH`
  (for example `main`, `master`, or `stable`).

**Preflight trusted repository identity and template status before flow resolution** — run:
```bash
ORIGIN_URL=$(git remote get-url origin 2>/dev/null || true)
gh repo view "$REPO_SLUG" --json nameWithOwner,isTemplate,url 2>/dev/null \
  || echo '{"nameWithOwner":null,"isTemplate":null,"url":null}'
cat AGENTS.md 2>/dev/null || true
```

Set `GH_IS_TEMPLATE` from GitHub (`true`, `false`, or `unknown`). Set
`GH_REPO_IDENTITY_VERIFIED=true` only when the trusted API `nameWithOwner` and URL agree
with the normalized `origin` remote. A directory basename, local marker, branch name, or
document is never repository identity. Unknown or conflicting API/remote results fail
closed.

Set `CANONICAL_APP_TEMPLATE_SOURCE=true` if and only if all of these facts are true:
- `GH_REPO_IDENTITY_VERIFIED=true`.
- `GH_IS_TEMPLATE=true`.
- The trusted API identity matches the exact lowercase pattern
  `^cloudopsworks/[a-z0-9][a-z0-9-]*-app-template$`.

Otherwise set `CANONICAL_APP_TEMPLATE_SOURCE=false`. This deliberately excludes forks,
implemented descendants, non-template repositories, unknown or mismatched identities,
skills repositories, and project templates such as `terraform-module-template` or
`terragrunt-project-template`. Capture the individual identity facts and the combined
decision; never infer it from a repository directory name.

**Detect GitVersion flow** — run:
```bash
CONFIG=.cloudopsworks/gitversion.yaml
CONFIG_TRACKED=false
CONFIG_IN_HEAD=false

if ! CONFIG_INDEX_OUTPUT=$(git ls-files -- "$CONFIG"); then
  echo "ERROR: failed to inspect Git index for $CONFIG; STOP before config-state resolution" >&2
  exit 1
fi
case "$CONFIG_INDEX_OUTPUT" in
  "") CONFIG_TRACKED=false ;;
  "$CONFIG") CONFIG_TRACKED=true ;;
  *)
    echo "ERROR: unexpected Git index output for $CONFIG: $CONFIG_INDEX_OUTPUT" >&2
    exit 1
    ;;
esac

if ! CONFIG_HEAD_OUTPUT=$(git ls-tree -r --name-only HEAD -- "$CONFIG"); then
  echo "ERROR: failed to inspect HEAD tree for $CONFIG; STOP before config-state resolution" >&2
  exit 1
fi
case "$CONFIG_HEAD_OUTPUT" in
  "") CONFIG_IN_HEAD=false ;;
  "$CONFIG") CONFIG_IN_HEAD=true ;;
  *)
    echo "ERROR: unexpected HEAD tree output for $CONFIG: $CONFIG_HEAD_OUTPUT" >&2
    exit 1
    ;;
esac

if [ -L "$CONFIG" ]; then
  CONFIG_STATE=invalid-or-deleted
  echo "SYMLINK_GITVERSION_CONFIG_NOT_ALLOWED"
elif [ -f "$CONFIG" ]; then
  CONFIG_STATE=present
  sed -n '1,220p' "$CONFIG"
elif [ ! -e "$CONFIG" ] \
  && [ "$CONFIG_TRACKED" = false ] && [ "$CONFIG_IN_HEAD" = false ]; then
  CONFIG_STATE=genuinely-absent
  echo "MISSING_GITVERSION_CONFIG"
else
  CONFIG_STATE=invalid-or-deleted
  echo "INVALID_OR_DELETED_GITVERSION_CONFIG"
fi
```

Both Git probes are mandatory preconditions. A nonzero exit or output other than empty
or the exact `$CONFIG` path is a probe failure and must **STOP before `CONFIG_STATE` is
assigned**; never reinterpret a Git error as absence. `genuinely-absent` means no file or
symlink exists at the path and both checked probes returned empty output. Test `-L`
before `-f`: every symlink is invalid, including a valid symlink whose target is a
readable regular file. A locally deleted tracked config, directory, or other non-regular
path is not absence eligible and must fail closed.

When `CONFIG_STATE=present`, read and validate the canonical selector before using
branch-name heuristics:

```bash
DECLARATION_LINES=$(grep -Ei '^[[:space:]]*#.*Agents.*WayOfWork' "$CONFIG" 2>/dev/null || true)
VALID_SELECTOR_LINES=$(grep -Ei '^[[:space:]]*#[[:space:]]*Agents:[[:space:]]*WayOfWork[[:space:]]*=[[:space:]]*[A-Za-z]+[[:space:]]*$' "$CONFIG" 2>/dev/null || true)
DECLARATION_COUNT=$(printf '%s\n' "$DECLARATION_LINES" | grep -c . || true)
SELECTOR_COUNT=$(printf '%s\n' "$VALID_SELECTOR_LINES" | grep -c . || true)
WAY_OF_WORK=$(printf '%s\n' "$VALID_SELECTOR_LINES" \
  | sed -E 's/^[[:space:]]*#[[:space:]]*[Aa][Gg][Ee][Nn][Tt][Ss]:[[:space:]]*[Ww][Aa][Yy][Oo][Ff][Ww][Oo][Rr][Kk][[:space:]]*=[[:space:]]*([A-Za-z]+)[[:space:]]*$/\1/' \
  | tr '[:upper:]' '[:lower:]')
```

The valid-line grammar above mirrors Tronador's
`(?mi)^\s*#\s*Agents:\s*WayOfWork\s*=\s*([A-Za-z]+)\s*$` parser: it accepts case and
whitespace variations, but no trailing text. Require
`DECLARATION_COUNT=SELECTOR_COUNT=1` for every present config; otherwise the metadata is
malformed, duplicated, or mixed and must fail closed even though the CLI itself retains
a legacy GitFlow fallback for missing/invalid headers.

Set `RELEASE_FLOW` using this fail-closed rule:
- Exactly one `gitflow` selector → `RELEASE_FLOW=gitflow`; require a `develop:` branch.
- Exactly one `githubflow` selector → `RELEASE_FLOW=githubflow`; a `hotfix:` branch is allowed, but a `develop:` branch contradicts the selector.
- Exactly one `trunk` or `trunkbased` selector → `RELEASE_FLOW=trunkbased`; `develop:`, `release:`, or `hotfix:` branch declarations contradict the selector.
- For each valid selector case above, set `FLOW_METADATA_STATUS=verified` and
  `FLOW_RESOLUTION_SOURCE=canonical-selector` after its branch-policy validation passes.
- When `CONFIG_STATE=genuinely-absent` and `CANONICAL_APP_TEMPLATE_SOURCE=true` →
  `RELEASE_FLOW=githubflow`, `WAY_OF_WORK=githubflow`,
  `FLOW_METADATA_STATUS=verified-app-template-absence-exception`, and
  `FLOW_RESOLUTION_SOURCE=verified-canonical-app-template-identity`. Do not create,
  edit, or stage a GitVersion config or selector merely to use this exception.
- Any absent config outside that exact exception; any present config with a missing
  selector, malformed/mixed declarations, duplicate selectors, unsupported values, or
  contradictory branch declarations; and every `invalid-or-deleted` config state →
  `RELEASE_FLOW=unverified` and **STOP before Step 3**. Never silently accept Tronador's
  missing-header GitFlow fallback.

The absence exception applies only when the config is genuinely absent; it never
overrides or repairs a present config. Branch-name structure and copied repo prose are
diagnostic only. Capture: `CONFIG_STATE`, `CONFIG_TRACKED`, `CONFIG_IN_HEAD`,
`CANONICAL_APP_TEMPLATE_SOURCE`, `WAY_OF_WORK`, `FLOW_METADATA_STATUS`,
`FLOW_RESOLUTION_SOURCE` (`canonical-selector` /
`verified-canonical-app-template-identity` / `unverified`), and `RELEASE_FLOW`
(`gitflow` / `githubflow` / `trunkbased` / `unverified`).

Use this decision table as the testable guard contract:

| Config state | `CANONICAL_APP_TEMPLATE_SOURCE` | Result |
|---|---:|---|
| Either Git probe fails or returns unexpected output | either | STOP before config-state resolution |
| Present, exactly one valid consistent selector | either | Resolve only from that selector |
| Present but missing/malformed/duplicate/unsupported/contradictory selector | either | `unverified`; STOP |
| Genuinely absent | `true` | `githubflow` via the bounded absence exception |
| Genuinely absent | `false` | `unverified`; STOP |
| Any symlink, including one targeting a valid selector file | either | `unverified`; STOP |
| Invalid path or locally deleted tracked config | either | `unverified`; STOP |

**Interpret bundled examples carefully:**
- `cw-release/gitflow/gitversion.yaml` = GitFlow reference where `+semver: breaking` implies MAJOR.
- `cw-release/githubflow/gitversion.yaml` = generic GitHubFlow reference where `+semver: breaking` also implies MAJOR.
- `cw-release/githubflow-cloudopsworks-spec/gitversion.yaml` = a CloudOps Works GitHubFlow reference in which `+semver: breaking` implies MINOR. It is a sample, **not** a description of any live repository — real repositories have diverged from it (for example `terraform-module-template` maps `breaking` to MAJOR and defines a `hotfix:` branch the sample omits).
- When a repository has `.cloudopsworks/gitversion.yaml`, that file is authoritative. **Never state what a repository's annotations do from a bundled sample** — read the regexes:
  ```bash
  grep -nE 'version-bump-message' .cloudopsworks/gitversion.yaml
  ```
  Resolve `SEMVER_ANNOTATION` against those patterns before using it.

**Complete repository template and version-file authority detection** — reuse the
trusted API identity and `GH_IS_TEMPLATE` facts captured before flow resolution, then run:
```bash
ls .cloudopsworks/_VERSION .github/_VERSION 2>/dev/null
if [ -f .cloudopsworks/.skills ] && [ ! -L .cloudopsworks/.skills ]; then
  echo "REGULAR_SKILLS_MARKER=true"
else
  echo "REGULAR_SKILLS_MARKER=false"
fi
```

Keep these decisions separate:
- `CLI_GENERATION_CAPABLE=true` only when Tronador's own guarded generation accepts the repository marker. Capability means the CLI may generate a file; it grants no release authority by itself.
- `SKILLS_SOURCE_OWNER=true` only for verified canonical identity `cloudopsworks/claude-code-skills` or `cloudopsworks/skill-builder-templates`, a known boolean GitHub template status, a regular, non-symlink `.cloudopsworks/.skills` marker, the canonical supported WayOfWork selector, and corroborating tracked `_VERSION` plus repo-local source-owner policy. Copied prose, an arbitrary/forked repository, a marker alone, unknown identity/template status, or a missing/symlink/non-regular marker never qualifies.

Set `VERSION_FILE_WRITABLE`:
- `true` when `GH_IS_TEMPLATE=true` (existing GitHub-template authority).
- `true` when `SKILLS_SOURCE_OWNER=true` (the bounded verified-source-owner exception).
- `false` otherwise, including unknown identity or template status.

The source-owner exception does **not** set `GH_IS_TEMPLATE` or `IS_TEMPLATE`, does not
change workflow ownership, and does not override `PUBLISH_MODE=ci`. In ordinary
implementation repositories `_VERSION` remains the template-generation marker owned by
`tronador repos upgrade`; writing the implementation's version there would corrupt the
next template-series resolution.

Set `IS_TEMPLATE` for template workflow policy:
- `true` when `GH_IS_TEMPLATE=true`.
- `true` only when `AGENTS.md` explicitly states this repository is a CloudOps
  Works template/source repository whose template workflows are edited locally.
- `false` otherwise. Do not infer it from `.skills` or set it as a side effect of
  `SKILLS_SOURCE_OWNER`.

Capture: `GH_REPO_IDENTITY_VERIFIED`, `GH_IS_TEMPLATE`, `CLI_GENERATION_CAPABLE`,
`SKILLS_SOURCE_OWNER`, `VERSION_FILE_WRITABLE`, and `IS_TEMPLATE`. Do not use any one
of these flags as a substitute for the others.

**Detect repo-local release policy and CI release ownership** — run:
```bash
cat AGENTS.md 2>/dev/null || true
ls .github/workflows/pr-merge-tagging.yml .github/workflows/release-management.yml 2>/dev/null || true

# Inspect every workflow and release configuration, not only conventionally
# named release workflows. Implementation repositories often publish from a
# main-build workflow after the PR merge.
find .github/workflows -maxdepth 1 -type f \
  \( -name '*.yml' -o -name '*.yaml' \) -print 2>/dev/null | sort
grep -RInE \
  'goreleaser|release-plz|cargo[[:space:]]+(publish|dist)|gh[[:space:]]+release|softprops/action-gh-release|gitflow/version/(tag|publish)|tronador[[:space:]]+versions[[:space:]]+tag[[:space:]]+--publish|release-management|create[^[:alnum:]]+release|upload[^[:alnum:]]+release' \
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
- `RUN_VERSION_FILE_BEFORE_PR=true` when `VERSION_FILE_WRITABLE=true` and `BUMP_COMMITS` is
  greater than zero. Count only `chore: Version Bump` commits — a
  `chore: Upgrade repository from template, version: …` commit is `tronador repos upgrade`
  writing the template generation marker, **not** a release bump, and every implementation
  repository has those. This flag can only cause a write when `VERSION_FILE_WRITABLE=true`.
- **When `VERSION_FILE_WRITABLE=true` (authorized template or verified source owner):** a version file that trails
  `LATEST_TAG` is **drift to be repaired, never policy to be matched.** Prior releases
  skipping the bump is a defect in those releases. Never reason "the last N releases left it
  stale, so I will too" — set `RUN_VERSION_FILE_BEFORE_PR=true` and let this release
  self-heal the file. Report the drift to the user.
- **When `VERSION_FILE_WRITABLE=false` (protected repository):** a version file
  that trails `LATEST_TAG` is **correct and expected** — it names the template generation,
  not this module's version. It is not drift. Do not repair it, do not report it as a
  defect, and do not set `RUN_VERSION_FILE_BEFORE_PR`.
- Set `CI_RELEASE_OWNER_DETECTED=true` for an implementation repository when any
  active workflow or repo-local release configuration can tag, publish, create a
  release, or invoke a release tool after merge. This includes
  `tronador versions tag --publish` under any workflow filename and GoReleaser for
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
git diff --cached --name-only
git diff --cached --stat
git diff --cached
git diff --name-only
git diff --stat
git diff
git ls-files --others --exclude-standard
git status --short
```

Read and understand what changed. Identify:
- **Nature of change**: documentation fix, bug fix, new feature, provider upgrade, breaking change, workflow/template upgrade.
- **Files touched**: classify each file as docs, implementation, workflow, boilerplate, or config.

Treat staged, unstaged, and untracked discovery separately; do not use a net
`git diff HEAD` result to infer cleanliness because staged content can be cancelled by a
different worktree version. **STOP HERE** only if all discovery commands succeed, all three
sets are empty, AND there is no user-specified content to commit. Tell the user: "No changes
detected. Nothing to release."

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
The `.cloudopsworks/_VERSION` and `.github/_VERSION` files are writable only when
`VERSION_FILE_WRITABLE=true`: existing GitHub-template authority or the bounded, verified
skills source-owner exception from Step 0. In every other repository they are protected
template-generation markers owned by `tronador repos upgrade`.

```bash
if ! VERSION_STAGED_PATHS=$(git diff --cached --name-only); then
  echo "ERROR: failed to scan staged protected-version changes" >&2
  exit 1
fi
if ! VERSION_UNSTAGED_PATHS=$(git diff --name-only); then
  echo "ERROR: failed to scan unstaged protected-version changes" >&2
  exit 1
fi
if ! VERSION_UNTRACKED_PATHS=$(git ls-files --others --exclude-standard); then
  echo "ERROR: failed to scan untracked protected-version files" >&2
  exit 1
fi

if VERSION_TRACKED_MATCHES=$(printf '%s\n%s\n' \
  "$VERSION_STAGED_PATHS" "$VERSION_UNSTAGED_PATHS" \
  | grep -E '^(\.cloudopsworks|\.github)/_VERSION$'); then
  if ! VERSION_IN_DIFF=$(printf '%s\n' "$VERSION_TRACKED_MATCHES" | sort -u); then
    echo "ERROR: failed to sort tracked protected-version changes" >&2
    exit 1
  fi
else
  VERSION_TRACKED_GREP_STATUS=$?
  if [ "$VERSION_TRACKED_GREP_STATUS" -eq 1 ]; then
    VERSION_IN_DIFF=""
  else
    echo "ERROR: failed to filter tracked protected-version changes" >&2
    exit 1
  fi
fi

if VERSION_UNTRACKED=$(printf '%s\n' "$VERSION_UNTRACKED_PATHS" \
  | grep -E '^(\.cloudopsworks|\.github)/_VERSION$'); then
  :
else
  VERSION_UNTRACKED_GREP_STATUS=$?
  if [ "$VERSION_UNTRACKED_GREP_STATUS" -eq 1 ]; then
    VERSION_UNTRACKED=""
  else
    echo "ERROR: failed to filter untracked protected-version files" >&2
    exit 1
  fi
fi

if VERSION_ALL_MATCHES=$(printf '%s\n%s\n' "$VERSION_IN_DIFF" "$VERSION_UNTRACKED" \
  | grep -v '^$'); then
  if ! ALL_VERSION_FILES=$(printf '%s\n' "$VERSION_ALL_MATCHES" | sort -u); then
    echo "ERROR: failed to sort all protected-version changes" >&2
    exit 1
  fi
else
  VERSION_ALL_GREP_STATUS=$?
  if [ "$VERSION_ALL_GREP_STATUS" -eq 1 ]; then
    ALL_VERSION_FILES=""
  else
    echo "ERROR: failed to combine protected-version changes" >&2
    exit 1
  fi
fi
echo "VERSION_FILES_IN_DIFF: $ALL_VERSION_FILES"
```

**If `VERSION_FILE_WRITABLE=true` OR `ALL_VERSION_FILES` is empty — skip Guard 4 and continue.**

If `VERSION_FILE_WRITABLE=false` AND `ALL_VERSION_FILES` is non-empty, **STOP.**
This guard is a hard block. Do not continue until every protected `_VERSION` change
is absent. Treat tracked changes and untracked files separately so the guard never
deletes user-owned content or reports a failed cleanup as successful.

First, if `VERSION_UNTRACKED` is non-empty, **do not delete or stage those files.**
Report the paths and STOP. Ask the user to remove or relocate the files themselves,
or to abort the release. Re-run Guard 4 from the beginning after the user has acted;
there is no continue option while an untracked protected file remains.

If there are no untracked protected files, restore each tracked protected file. Every
command is required to succeed; an error is a hard failure that must name the affected
path and STOP the release:

```bash
for vf in $VERSION_IN_DIFF; do
  git ls-files --error-unmatch -- "$vf" >/dev/null || {
    echo "ERROR: protected _VERSION path is not tracked: $vf" >&2
    exit 1
  }
  git restore --source=HEAD --staged --worktree -- "$vf" || {
    echo "ERROR: failed to restore protected _VERSION path: $vf" >&2
    exit 1
  }
done

if ! RESIDUAL_VERSION_STAGED=$(git diff --cached --name-only); then
  echo "ERROR: failed to rescan staged protected-version changes" >&2
  exit 1
fi
if ! RESIDUAL_VERSION_UNSTAGED=$(git diff --name-only); then
  echo "ERROR: failed to rescan unstaged protected-version changes" >&2
  exit 1
fi
if ! RESIDUAL_VERSION_UNTRACKED=$(git ls-files --others --exclude-standard); then
  echo "ERROR: failed to rescan untracked protected-version files" >&2
  exit 1
fi

if RESIDUAL_VERSION_MATCHES=$(printf '%s\n%s\n%s\n' \
  "$RESIDUAL_VERSION_STAGED" "$RESIDUAL_VERSION_UNSTAGED" "$RESIDUAL_VERSION_UNTRACKED" \
  | grep -E '^(\.cloudopsworks|\.github)/_VERSION$'); then
  if ! RESIDUAL_VERSION_FILES=$(printf '%s\n' "$RESIDUAL_VERSION_MATCHES" | sort -u); then
    echo "ERROR: failed to sort residual protected-version changes" >&2
    exit 1
  fi
else
  RESIDUAL_VERSION_GREP_STATUS=$?
  if [ "$RESIDUAL_VERSION_GREP_STATUS" -eq 1 ]; then
    RESIDUAL_VERSION_FILES=""
  else
    echo "ERROR: failed to filter residual protected-version changes" >&2
    exit 1
  fi
fi

if [ -n "$RESIDUAL_VERSION_FILES" ]; then
  echo "ERROR: protected _VERSION changes remain after cleanup:" >&2
  printf '%s\n' "$RESIDUAL_VERSION_FILES" >&2
  exit 1
fi
```

Only after all tracked restores succeed and `RESIDUAL_VERSION_FILES` is empty, use
`AskUserQuestion` to inform the user:

State:
- The project slug and current branch.
- That this repository is **not authorized to write `_VERSION`** because Step 0
  established neither GitHub-template authority nor the bounded verified skills
  source-owner exception.
- The list of tracked files that were successfully restored from `HEAD`.
- That in this repository `_VERSION` records the template generation and is written only by
  `tronador repos upgrade`; release version updates originate from the template repository.

Options:
- A) Continue the release without the `_VERSION` change (tracked files were restored and the
  post-cleanup scan is empty)
- B) Abort the release — this repository should not update `_VERSION` this way

If the user chooses A: continue to the workflow file checks below.
If the user chooses B: **STOP** the entire release workflow. Do not proceed.

---

Now detect workflow file changes for Guards 1–3:

```bash
if ! STAGED_PATHS=$(git diff --cached --name-only); then
  echo "ERROR: failed to scan staged workflow changes" >&2
  exit 1
fi
if ! UNSTAGED_PATHS=$(git diff --name-only); then
  echo "ERROR: failed to scan unstaged workflow changes" >&2
  exit 1
fi
if ! UNTRACKED_PATHS=$(git ls-files --others --exclude-standard); then
  echo "ERROR: failed to scan untracked workflow files" >&2
  exit 1
fi

if CHANGED_MATCHES=$(printf '%s\n%s\n' "$STAGED_PATHS" "$UNSTAGED_PATHS" \
  | grep -E '^\.github/workflows/.*\.(yml|yaml)$'); then
  if ! CHANGED_WORKFLOWS=$(printf '%s\n' "$CHANGED_MATCHES" | sort -u); then
    echo "ERROR: failed to sort tracked workflow changes" >&2
    exit 1
  fi
else
  CHANGED_GREP_STATUS=$?
  if [ "$CHANGED_GREP_STATUS" -eq 1 ]; then
    CHANGED_WORKFLOWS=""
  else
    echo "ERROR: failed to filter tracked workflow changes" >&2
    exit 1
  fi
fi

if ADDED_WORKFLOWS=$(printf '%s\n' "$UNTRACKED_PATHS" \
  | grep -E '^\.github/workflows/.*\.(yml|yaml)$'); then
  :
else
  ADDED_GREP_STATUS=$?
  if [ "$ADDED_GREP_STATUS" -eq 1 ]; then
    ADDED_WORKFLOWS=""
  else
    echo "ERROR: failed to filter untracked workflow files" >&2
    exit 1
  fi
fi

if ALL_MATCHES=$(printf '%s\n%s\n' "$CHANGED_WORKFLOWS" "$ADDED_WORKFLOWS" \
  | grep -v '^$'); then
  ALL_CHANGED_WORKFLOWS=$(printf '%s\n' "$ALL_MATCHES" | sort -u) || {
    echo "ERROR: failed to sort workflow changes" >&2
    exit 1
  }
else
  ALL_GREP_STATUS=$?
  if [ "$ALL_GREP_STATUS" -eq 1 ]; then
    ALL_CHANGED_WORKFLOWS=""
  else
    echo "ERROR: failed to combine workflow changes" >&2
    exit 1
  fi
fi
echo "CHANGED_WORKFLOWS:"
echo "$ALL_CHANGED_WORKFLOWS"
```

All three Git discovery commands are mandatory. A nonzero staged `git diff`, unstaged
`git diff`, or `git ls-files`
status is a scan failure and STOPS the workflow before any grep/filter decision;
only grep status 1 (no matching workflow paths) is an allowed empty result.

**If `ALL_CHANGED_WORKFLOWS` is empty — skip Guards 1–3 and continue to Step 2.**

---

### Guard 1 — Non-template repository: workflow file protection

**Applies when:** `IS_TEMPLATE=false` AND `ALL_CHANGED_WORKFLOWS` is non-empty.

**This guard is a hard block. There is no clearance path and no bypass option.**
Workflow files in non-template repositories are normally owned by upstream
templates or repo-local maintainers, not by a generic release pass.
The agent must not commit, push, or release them under any circumstance.

**STOP.** Restore only tracked workflow changes. Preserve every untracked workflow
file byte-for-byte. Every restore command must succeed, and a clean residual scan
is required before the guard may report success or offer continuation:

```bash
while IFS= read -r wf; do
  [ -n "$wf" ] || continue
  git ls-files --error-unmatch -- "$wf" >/dev/null || {
    echo "ERROR: protected workflow is not tracked: $wf" >&2
    exit 1
  }
  git restore --source=HEAD --staged --worktree -- "$wf" || {
    echo "ERROR: failed to restore protected workflow: $wf" >&2
    exit 1
  }
done <<EOF
$CHANGED_WORKFLOWS
EOF

if [ -n "$ADDED_WORKFLOWS" ]; then
  echo "ERROR: untracked protected workflow files were preserved; release remains blocked:" >&2
  printf '%s\n' "$ADDED_WORKFLOWS" >&2
  exit 1
fi

if ! RESIDUAL_STAGED_PATHS=$(git diff --cached --name-only); then
  echo "ERROR: failed to rescan staged workflow changes" >&2
  exit 1
fi
if ! RESIDUAL_UNSTAGED_PATHS=$(git diff --name-only); then
  echo "ERROR: failed to rescan unstaged workflow changes" >&2
  exit 1
fi
if ! RESIDUAL_UNTRACKED_PATHS=$(git ls-files --others --exclude-standard); then
  echo "ERROR: failed to rescan untracked workflow files" >&2
  exit 1
fi

if RESIDUAL_MATCHES=$(printf '%s\n%s\n%s\n' \
  "$RESIDUAL_STAGED_PATHS" "$RESIDUAL_UNSTAGED_PATHS" "$RESIDUAL_UNTRACKED_PATHS" \
  | grep -E '^\.github/workflows/.*\.(yml|yaml)$'); then
  RESIDUAL_WORKFLOWS=$(printf '%s\n' "$RESIDUAL_MATCHES" | sort -u) || {
    echo "ERROR: failed to sort residual workflow changes" >&2
    exit 1
  }
else
  RESIDUAL_GREP_STATUS=$?
  if [ "$RESIDUAL_GREP_STATUS" -eq 1 ]; then
    RESIDUAL_WORKFLOWS=""
  else
    echo "ERROR: failed to filter residual workflow changes" >&2
    exit 1
  fi
fi

if [ -n "$RESIDUAL_WORKFLOWS" ]; then
  echo "ERROR: protected workflow changes remain after restore:" >&2
  printf '%s\n' "$RESIDUAL_WORKFLOWS" >&2
  exit 1
fi
```

The same fail-closed rule applies to the residual scan: all three Git commands must
succeed before filtering, and only grep status 1 may mean no residual workflows.

For untracked-only or mixed tracked/untracked input, STOP after reporting the
preserved untracked paths. Do not delete, stage, overwrite, or offer a continue
choice. A failed tracked restore or any staged, unstaged, or untracked residual
also STOPS with the affected path; never claim restoration succeeded and never
reach branch, commit, or merge operations.

Only after all tracked restores succeed and `RESIDUAL_WORKFLOWS` is empty, use
`AskUserQuestion` to inform the user:

State:
- The project slug and current branch.
- That this is **not a template repository** under the detected policy —
  tracked workflow files under `.github/workflows/` have been restored from `HEAD`.
- The list of tracked files that were successfully restored.
- That if this change is genuinely required, it must go through the upstream
  template/source repository, or the local `AGENTS.md` must explicitly say this
  repository owns workflow edits.

Options:
- A) Continue the release without the workflow changes (tracked files were restored
  and the post-restore scan is empty)
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
while true; do
  if IFS= read -r wf; then
    :
  else
    WORKFLOW_READ_STATUS=$?
    if [ "$WORKFLOW_READ_STATUS" -eq 1 ]; then
      break
    fi
    echo "ERROR: failed to read changed workflow list for Guard 2" >&2
    exit 1
  fi
  [ -n "$wf" ] || continue
  if [ ! -f "$wf" ] || [ ! -r "$wf" ]; then
    echo "ERROR: changed workflow is missing, non-regular, or unreadable: $wf" >&2
    exit 1
  fi
  if MATCHES=$(grep -nE \
    'uses:.*(cloudopsworks/blueprints|\.\/bp).*@v[0-9]+\.[0-9]+\.[0-9]+' "$wf"); then
    :
  else
    MATCH_GREP_STATUS=$?
    if [ "$MATCH_GREP_STATUS" -eq 1 ]; then
      MATCHES=""
    else
      echo "ERROR: failed to scan workflow for Guard 2: $wf" >&2
      exit 1
    fi
  fi
  [ -n "$MATCHES" ] && BLUEPRINT_VIOLATIONS="${BLUEPRINT_VIOLATIONS}  [${wf}]
${MATCHES}
"
done <<EOF
$ALL_CHANGED_WORKFLOWS
EOF
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

Scan every changed workflow file for external `uses:` entries that are **not**
`cloudopsworks/blueprints` or `./bp`. The normal required format is `@vX` (major only).
The one reviewed exception is exactly
`gittools/actions/gitversion/setup@7417b1089e2c7de93510f1901d656ddf60bb024f`
(GitTools/actions v4.7.0 setup, pinned immutably for GitVersion 6.7.0 compatibility).
The SHA on any other action path, any other GitTools SHA, and all other non-major pins
remain violations.

```bash
OTHER_VIOLATIONS=""
while true; do
  if IFS= read -r wf; then
    :
  else
    WORKFLOW_READ_STATUS=$?
    if [ "$WORKFLOW_READ_STATUS" -eq 1 ]; then
      break
    fi
    echo "ERROR: failed to read changed workflow list for Guard 3" >&2
    exit 1
  fi
  [ -n "$wf" ] || continue
  if [ ! -f "$wf" ] || [ ! -r "$wf" ]; then
    echo "ERROR: changed workflow is missing, non-regular, or unreadable: $wf" >&2
    exit 1
  fi

  if USES_LINES=$(grep -nE '^[[:space:]]*(- )?uses:' "$wf"); then
    :
  else
    USES_GREP_STATUS=$?
    if [ "$USES_GREP_STATUS" -eq 1 ]; then
      USES_LINES=""
    else
      echo "ERROR: failed to scan workflow for Guard 3: $wf" >&2
      exit 1
    fi
  fi

  FILE_VIOLATIONS=""
  while true; do
    if IFS= read -r line; then
      :
    else
      USES_READ_STATUS=$?
      if [ "$USES_READ_STATUS" -eq 1 ]; then
        break
      fi
      echo "ERROR: failed to read uses entries for Guard 3: $wf" >&2
      exit 1
    fi
    [ -n "$line" ] || continue
    if ! ref=$(printf '%s\n' "$line" | sed -E \
      -e 's/^[0-9]+:[[:space:]]*(- )?uses:[[:space:]]*//' \
      -e 's/[[:space:]#].*$//'); then
      echo "ERROR: failed to parse uses entry for Guard 3: $wf" >&2
      exit 1
    fi
    case "$ref" in
      ./*|cloudopsworks/blueprints/*@*) continue ;;
      gittools/actions/gitversion/setup@7417b1089e2c7de93510f1901d656ddf60bb024f) continue ;;
      *@v[0-9]*)
        if printf '%s\n' "$ref" | grep -Eq '@v[0-9]+$'; then
          continue
        else
          REF_GREP_STATUS=$?
          if [ "$REF_GREP_STATUS" -gt 1 ]; then
            echo "ERROR: failed to validate action pin for Guard 3: $wf" >&2
            exit 1
          fi
        fi
        ;;
    esac
    FILE_VIOLATIONS="${FILE_VIOLATIONS}${line}
"
  done <<EOF_USES
$USES_LINES
EOF_USES

  [ -n "$FILE_VIOLATIONS" ] && OTHER_VIOLATIONS="${OTHER_VIOLATIONS}  [${wf}]
${FILE_VIOLATIONS}
"
done <<EOF
$ALL_CHANGED_WORKFLOWS
EOF
printf '%s\n' "OTHER_VIOLATIONS:${OTHER_VIOLATIONS}"
```

**If `OTHER_VIOLATIONS` is empty — skip Guard 3 and continue to Step 2.**

If violations are found, **STOP.** Use `AskUserQuestion`:

State:
- The project slug, current branch, and each violation (file path, line number, and offending `uses:` value).
- That template workflow files must reference external actions with major-only version pins (`@vX`), except for the one exact reviewed GitTools setup SHA.
- Correct format examples: `uses: actions/checkout@v4`, `uses: hashicorp/setup-terraform@v3`

Options:
- A) Auto-correct — strip minor/patch segments from version-tag violations; do not rewrite unknown SHA violations automatically
- B) Proceed with clearance — I confirm these pinned versions are intentional

If the user chooses A: for each flagged version-tag `uses:` line use the `Edit` tool to
replace `@vX.Y.Z` or `@vX.Y` with `@vX`. A non-allowlisted SHA requires explicit
review; never convert it by guessing a tag.
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

### If `RELEASE_FLOW=githubflow` or `RELEASE_FLOW=trunkbased`

| Change Nature                            | Branch Type | Semver Level | Annotation                    |
|------------------------------------------|-------------|--------------|-------------------------------|
| Docs-only fix / wording correction       | `feature`   | PATCH        | `+semver: patch`              |
| Workflow / template upgrade (patch)      | `feature`   | PATCH        | `+semver: patch` or `+semver: hotfix` |
| Bug fix in implementation                | `feature`   | PATCH        | `+semver: fix`                |
| Workflow / template upgrade (minor)      | `feature`   | MINOR        | `+semver: minor`              |
| New module feature                       | `feature`   | MINOR        | `+semver: feature`            |
| Provider upgrade (backwards-compatible)  | `feature`   | MINOR        | `+semver: minor`              |
| Provider major upgrade / breaking change | `feature`   | MAJOR        | `+semver: major`              |
| Explicit compatibility break             | `feature`   | MAJOR        | `+semver: major`              |

> **GitHubFlow reminder:** `+semver: breaking` is **not portable** — it lands in
> `major-version-bump-message` in some repositories and `minor-version-bump-message` in
> others, and the bundled samples disagree with live configs. Read
> `grep -nE 'version-bump-message' .cloudopsworks/gitversion.yaml` and classify the
> annotation from that file before selecting it. Prefer `+semver: major` / `+semver: minor`,
> which are unambiguous in every configuration seen so far.

Capture: `BRANCH_TYPE` (usually `feature` or `hotfix`), `SEMVER_ANNOTATION`, `SEMVER_LEVEL`. Avoid `fix/*` as a default branch strategy because it is not a first-class GitVersion branch in either bundled config.

Resolve the pull-request destination independently from the repository's release
destination:
- If `RELEASE_FLOW=gitflow` and `BRANCH_TYPE=feature`, set `PR_BASE=develop` and
  `GITFLOW_FEATURE_DELIVERY=true`.
- Otherwise, set `PR_BASE=<PRIMARY_BRANCH>` and
  `GITFLOW_FEATURE_DELIVERY=false`.

This keeps feature creation and delivery aligned: Tronador starts GitFlow features
from `develop`, so their PRs return to `develop`; GitHubFlow and trunk-based feature
PRs target the verified configured primary branch. A later, separately invoked
GitFlow release-branch workflow owns promotion from `develop`, tagging, and release.

After `BRANCH_TYPE` is known, set `PURGE_RELEASE_BRANCH`:
- If `IS_TEMPLATE=true` **and** `BRANCH_TYPE=feature` → `PURGE_RELEASE_BRANCH=true`
- Otherwise → `PURGE_RELEASE_BRANCH=false`

Except for `GITFLOW_FEATURE_DELIVERY=true`, template repositories should not retain
merged `feature/*` release branches locally or remotely. GitFlow feature delivery
preserves its source branch and terminates after the `develop` merge/CI snapshot.

---

## Step 3: Determine Branch Name

Choose the branch strategy that matches `RELEASE_FLOW`.

For `RELEASE_FLOW=gitflow` and `BRANCH_TYPE=hotfix`, Tronador auto-names the branch with the version bump:
```bash
tronador versions hotfix start
BRANCH=$(git branch --show-current)
```

For `feature` branches, derive a short slug from the changed files or change
nature (max 30 chars, kebab-case, no special chars). Examples: `agents-md-guidelines`,
`vpc-outputs`, `provider-upgrade-v5`.

For any verified flow and `BRANCH_TYPE=feature`, use the positional CLI form:
```bash
tronador versions feature start "<slug>"
BRANCH="feature/<slug>"
```

This is an intentional migration from legacy `start-no-develop`: Tronador bases the
feature on `develop` for GitFlow and on the configured primary branch for GitHubFlow or
trunk-based flow. Do not run it until either the canonical selector is verified and
consistent or the captured flow status is the narrowly bounded
`verified-app-template-absence-exception`; no other missing-config repository satisfies
this gate.

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

## Step 6: Generate and Commit `_VERSION` When Repo Policy Requires It

Run `tronador project version --generate --yes` only when Step 0 has established
`VERSION_FILE_WRITABLE=true` through verified GitHub-template or bounded source-owner
authority. When authorized, it computes and writes `_VERSION` only; it does not commit,
tag, push, publish, or open a PR. The generated file must pass the same review, staging,
conventional-commit, and push controls as any other source change.

Decision rule:
- If `GITFLOW_FEATURE_DELIVERY=true` → **skip this step.** A GitFlow feature PR
  delivers to `develop`; the separate release-branch workflow owns release-version
  generation, promotion, tagging, and publication.
- **GUARD (hard block, no bypass):** If `VERSION_FILE_WRITABLE=false` → **skip this step
  entirely.** Only existing GitHub-template authority or the verified skills source-owner
  exception from Step 0 may write `_VERSION`; marker capability or copied prose alone
  cannot lift it. Proceed directly to the
  read-only path below and then continue to Step 7.
- If `VERSION_FILE_WRITABLE=true` AND `RUN_VERSION_FILE_BEFORE_PR=true` → run this step.
- If `VERSION_FILE_WRITABLE=true` AND `RUN_VERSION_FILE_BEFORE_PR=false` → **run this step
  anyway** unless the repository has no version file at all (`NO_VERSION_FILE`). Running is
  the default once the file exists and Step 0 established write authority.

**When `VERSION_FILE_WRITABLE=true`, never infer "skip" from any of the following** — each is
a symptom of the bug this step exists to prevent, not a policy signal:
- The version file is stale relative to the latest tag.
- Recent releases did not bump it.
- `AGENTS.md` does not mention `gitflow/version/file` in its numbered workflow.

In an authorized repository, when the file exists and this branch will produce a release,
generation runs. In every protected repository this step is unconditionally skipped.

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
tronador project version --generate --yes
git diff -- .cloudopsworks/_VERSION .github/_VERSION
git status --short
```

Inspect the generated diff, stage only the authorized version file, create the repository's
required conventional `chore: Version Bump` commit, and push the current branch before
Step 7. Do not continue with an uncommitted or unpushed generated file.

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

**STOP** if generation, review, commit, or push fails. Show the error and ask the user how to proceed.

---

## Step 7: Create Pull Request

Build the PR body with `+semver: <level>` in the **body** (not just the title) so
GitVersion picks it up during merge.

```bash
gh pr create \
  --repo <REPO_SLUG> \
  --base <PR_BASE> \
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
- If `GITFLOW_FEATURE_DELIVERY=true` → use `--delete-branch=false`. This rule has
  highest priority: preserve the GitFlow feature source branch at merge time for
  the separate release-branch workflow and do not defer preservation to cleanup.
- Else if `PURGE_RELEASE_BRANCH=true` AND `PRESERVE_REMOTE_BRANCH=false` → use `--delete-branch`
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

### GitFlow feature delivery terminal path

If `GITFLOW_FEATURE_DELIVERY=true`, do **not** enter release observer mode. The
feature has merged into `develop`, not the configured primary/release destination.
Take one read-only snapshot of post-merge CI for the exact merge commit:

```bash
if FEATURE_RUNS=$(gh run list --repo <REPO_SLUG> --commit <MERGE_SHA> --limit 100 \
  --json databaseId,name,workflowName,event,status,conclusion,url); then
  if FEATURE_CI_CLASSIFICATION=$(printf '%s' "$FEATURE_RUNS" | jq -r '
    if length == 0 then "absent"
    elif any(.status != "completed") then "pending"
    elif any(.conclusion != "success" and .conclusion != "skipped" and .conclusion != "neutral") then "failed"
    else "successful" end'); then
    FEATURE_CI_STATUS=$FEATURE_CI_CLASSIFICATION
  else
    FEATURE_CI_STATUS=unavailable
  fi
else
  FEATURE_CI_STATUS=unavailable
  FEATURE_RUNS='[]'
fi
printf '%s\n' "$FEATURE_RUNS"
```

Then print this dedicated terminal summary and **end the workflow**, regardless of
whether CI is absent, pending, failed, successful, or unavailable:

```text
## Feature Delivery Terminal Summary

- Branch:     <BRANCH> (preserved; no merge-time or post-merge deletion)
- PR:         #<PR_NUMBER> → develop (merged at <MERGE_SHA>)
- CI status:  <FEATURE_CI_STATUS plus observed run URLs, if any>
- Release:    not performed; a separate GitFlow release-branch workflow owns
              promotion to <PRIMARY_BRANCH>, tagging, and publication
```

This path must not execute Step 10 primary synchronization, Step 11 cleanup,
Steps 12–14 publication, or the generic release Step 15/checklist. Do not create a
release branch automatically, and do not tag, publish, create/edit a GitHub Release,
or claim that a release occurred. CI failure or absence is reported evidence, not a
fallback into release or cleanup behavior.

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

- Do not run `tronador project version --generate --yes`,
  `tronador versions tag --publish`, GoReleaser, Cargo release/publish commands, or
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

## Step 10: Sync Configured Primary

```bash
git checkout <PRIMARY_BRANCH>
git pull origin <PRIMARY_BRANCH>
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

Tag and publish via Tronador CLI is applicable only when `PUBLISH_MODE=local`.

Decision rule:
- If `PUBLISH_MODE=ci` → skip this entire step and proceed to Step 15. CI owns
  tag + release after merge. This is an absolute ownership boundary, not a race:
  never run local tagging/publication even if CI is slow, fails, is cancelled,
  waits for approval, or has not produced a tag or release yet.
- If `PUBLISH_MODE=local` → run both targets below.

If `PUBLISH_MODE=local`, run:

```bash
git fetch origin --tags --prune
tronador versions tag --publish
```

Capture the tag name from output (e.g. `Tagged v1.7.0...`). Confirm:
```bash
git tag --sort=-v:refname | head -3
```

**STOP** if tagging fails with "must be in the latest commit of the branch". This means
remote is ahead — run `git pull origin <PRIMARY_BRANCH>` and retry.

**If Tronador exits non-zero with "already exists"** in a positively identified
local-publish repository, stop mutating and verify read-only whether an external
publisher created the tag:
```bash
git fetch --tags && git tag --sort=-v:refname | head -3
```
Do not race that publisher or overwrite its output. Reclassify the repository as
`PUBLISH_MODE=ci`, enter release observer mode, and skip Steps 13-14.

> **Note:** `tronador versions tag --publish` guarantees the git tag is pushed to the
> remote. It does **not** guarantee a GitHub release is created. Always proceed through Steps 13–14 to build the
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
rather than enforcing a local publisher's tag invariant. When
`VERSION_FILE_WRITABLE=true`, also verify that the generated `_VERSION` change was
committed in the merged PR; when false, report the file as protected:

```bash
git fetch origin --tags --prune
VERSION_PATH=$(ls .cloudopsworks/_VERSION .github/_VERSION 2>/dev/null | head -1)
printf 'VERSION_FILE_WRITABLE=%s\nVERSION_PATH=%s\n' "$VERSION_FILE_WRITABLE" "$VERSION_PATH"
if [ "$VERSION_FILE_WRITABLE" = true ] && [ -n "$VERSION_PATH" ]; then
  git show --stat --oneline <MERGE_SHA> -- "$VERSION_PATH"
  cat "$VERSION_PATH"
fi
gh run list --repo <REPO_SLUG> --commit <MERGE_SHA> --limit 100 \
  --json databaseId,name,workflowName,event,status,conclusion,url
gh release list --repo <REPO_SLUG> --limit 10
git tag --sort=-v:refname | head -3
```

Do not create or repair anything when expected CI output is absent. Report the
authorized committed version-file value (or `protected`), workflow state,
observed tag/release (or `pending` / `missing`), and workflow URLs. A failed or
incomplete CI-owned release is not a local-release fallback.

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

- **Never push directly to the configured primary branch.** Always use a feature,
  hotfix, or release branch selected by the verified flow policy.
- **Never squash or rebase on merge.** Always `--merge`.
- **`+semver:` annotation must be in the body of the merge commit**, not just the title, for GitVersion to pick it up.
- **Only when `VERSION_FILE_WRITABLE=true`, `tronador project version --generate --yes` changes `_VERSION`.** Review, stage, commit, and push it explicitly before the PR; otherwise never run it.
- **`tronador versions hotfix start` auto-names the branch** with the bumped patch version. Capture the branch name after running it.
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
- **GitFlow feature delivery terminates after the develop merge and one read-only CI
  snapshot.** Preserve the source branch during Step 9 and do not enter Steps 10–15,
  regardless of repository template status or CI outcome. A separate release-branch
  workflow owns promotion and release.
- **GitHub template repos use `PUBLISH_MODE=local` for actual release runs** — when
  `GH_IS_TEMPLATE=true`, GitHub Actions are disabled and no CI workflow will ever run,
  even if `pr-merge-tagging.yml` or `release-management.yml` exist in
  `.github/workflows/`. The `PUBLISH_MODE=ci` detection from workflow file presence is
  overridden to `PUBLISH_MODE=local` in Step 0. Except for the terminal GitFlow feature
  delivery path, run Steps 12–14 for template release runs.
- **`tronador versions tag --publish` pushes the tag** — it does not create a
  GitHub release. In a positively identified local-publish repository, continue
  to Steps 13–14 and use `gh release create` only when no release exists.
- **If `gh pr checks` or `statusCheckRollup` reports no checks** — this is ambiguous: checks may not have registered yet. Always complete Step 8a–8b (60-second poll + CI presence check) before concluding CI is absent. Never interpret "no checks" as "no CI" without evidence. **Exception: when `GH_IS_TEMPLATE=true`, no checks will ever register** — GitHub disables Actions on template repositories by default. Skip the poll entirely; `CI_REQUIRED=false` for all template repos regardless of what workflows exist in `.github/workflows/`.
- **Git lock files** (`.git/index.lock`): if encountered, run `rm -f .git/index.lock` before retrying.
- **Stale hotfix branches**: if `tronador versions hotfix start` fails with a branch-exists error, check with `git branch -a | grep hotfix` and delete stale ones with `git branch -D hotfix/<version>`.
- **Never use `--no-verify`** on commits or pushes.
- **Uncommitted changes must become a conventional commit before release actions continue.** Do not push, open a PR, merge, tag, or publish while relevant release changes remain uncommitted.
- **If repo-local policy requires commit trailers** (for example Lore-style
  decision-record trailers), preserve them in addition to the conventional
  commit subject and semver annotation.
- **`fix/` branches** are not first-class GitVersion branches in either bundled config and are not first-class in the supported Tronador version workflows. Prefer `feature/*` by default, and use `hotfix/*` only when the detected flow and repo automation support it.
- **GitVersion flow detection** (Step 0):
  - The single canonical `# Agents: WayOfWork=...` selector is authoritative.
  - Support `gitflow`, `githubflow`, and existing `trunk` / `trunkbased` values.
  - A GitHubFlow config may contain `hotfix:`; branch-name heuristics never override the selector.
  - A genuinely absent config resolves to GitHub Flow only when trusted API identity
    agrees with `origin`, GitHub reports `isTemplate=true`, and the exact canonical
    identity matches `cloudopsworks/*-app-template`. This identity-based exception does
    not create or modify a selector.
  - Index and `HEAD` config probes must both succeed and return either empty output or
    the exact config path. Probe errors or unexpected output STOP before config-state
    resolution and can never be treated as absence.
  - Missing config outside that exception, any config-path symlink, a deleted tracked
    config, malformed or duplicate selectors, unsupported values, and contradictory
    metadata fail closed before branch creation. Present regular-file config always
    remains authoritative.
  - Flow detection controls branch choice, feature base, and semver interpretation for `tronador versions ...`.
- **Repo-local release policy overrides generic heuristics** (Step 0 / Steps 6, 12-14):
  - If `AGENTS.md` says GitHub Actions handle releases, set `PUBLISH_MODE=ci` and skip local release creation.
  - GitHub `isTemplate=true` grants existing authority; the only additional authority is the bounded verified source-owner exception for the two exact canonical skills repositories. A marker or copied `AGENTS.md` sentence alone never grants it.
  - Use `IS_TEMPLATE` only for template workflow policy and branch-cleanup heuristics; it does **not** override explicit repo-local publish or version-file policy.
- **GitHubFlow semver note**: some repos intentionally map `+semver: breaking` to MINOR. Always trust the repo's actual `major-version-bump-message` / `minor-version-bump-message` config over generic assumptions.
- **In an authorized repository (`VERSION_FILE_WRITABLE=true`), a stale `_VERSION` is a defect, never a convention.** When the file trails the latest tag, prior releases skipped Step 6. Repair it by running Step 6 on this release — never by hand-editing, and never by "staying consistent" with the releases that skipped it.
- **In every protected repository, a `_VERSION` that trails the latest tag is correct.** It records the template generation, not the module's release version. Never "repair" it, and never report it as drift.
- **`_VERSION` write protection (`VERSION_FILE_WRITABLE=false`):** `.cloudopsworks/_VERSION` and `.github/_VERSION` must never be written, staged, or committed when `VERSION_FILE_WRITABLE=false`. Step 6 (`tronador project version --generate --yes`) is unconditionally skipped in that state, even if `RUN_VERSION_FILE_BEFORE_PR=true`. Writing it corrupts `tronador repos upgrade` template-tag resolution. If `_VERSION` already appears in the diff while protected, Guard 4 in Step 1.5 reverts it immediately. This check runs before any branch, commit, or push action.
- **Fetch tags before version calculation:** Run `git fetch origin --tags --prune` before any GitVersion-based `_VERSION`, tag, or publish calculation. Do not continue if the computed `_VERSION` is lower than the latest fetched remote tag.
- **Workflow Safety Guard (Step 1.5) is mandatory and never skipped** when workflow files appear in the diff. It is the primary mechanism that prevents AI agents from silently modifying workflows in non-template repos or introducing bad version pins in templates. Any bypass requires explicit user clearance via `AskUserQuestion`.
- **Non-template repos must not modify workflow files — hard block, no bypass.** If
  `.github/workflows/*.yml` or `.github/workflows/*.yaml` files appear for an
  `IS_TEMPLATE=false` repo, Guard 1 restores tracked changes through checked commands,
  preserves untracked files, and requires an empty residual scan. Untracked, mixed,
  failed-restore, or residual cases STOP without continuation. Workflow changes must go
  through the upstream template/source repository, or local `AGENTS.md` must explicitly
  define that this repository owns workflow edits.
- **Template repos: blueprints/bp actions must use `@vX.Y` pins.** `uses:` entries referencing `cloudopsworks/blueprints` or `./bp` must carry exactly a major.minor version tag (e.g. `@v5.10`). Full three-part semver (`@v5.10.3`) is a Guard 2 violation regardless of which branch is active.
- **Template repos: all other external actions must use `@vX` (major-only) pins.** The only exception is exact `gittools/actions/gitversion/setup@7417b1089e2c7de93510f1901d656ddf60bb024f`; a different path/SHA or any unrelated non-major pin remains a Guard 3 violation.
- **User clearance on any guard is final for that session.** Once a guard is cleared with option B, do not re-fire it for the same workflow files in the same release run. However, if new workflow files appear (e.g. the user adds more), re-evaluate all applicable guards for the new files.
