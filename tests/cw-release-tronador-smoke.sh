#!/usr/bin/env bash
# Offline smoke test for the branch operations documented in cw-release.
set -euo pipefail

tronador_bin=$(command -v tronador) || {
  printf '%s\n' 'Tronador CLI is required on PATH' >&2
  exit 1
}

test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

# Ignore developer Git config and restrict every Git child process to local
# repositories, including those launched by Tronador.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_ALLOW_PROTOCOL=file

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

init_fixture() {
  local name=$1 primary=$2 remote=$3
  git init --bare --quiet "$remote"
  git init --quiet --initial-branch="$primary" "$test_root/$name"
  cd "$test_root/$name"
  git config user.name 'Release Smoke Test'
  git config user.email 'release-smoke@example.invalid'
  git remote add origin "$remote"
}

init_tool_stubs() {
  cat > "$test_root/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "${1-}" == --version ]]; then
  printf '%s\n' 'gh version 2.99.0'
  exit 0
fi
printf '%s\n' "$@" >> "$GH_ARGS"
printf '%s\n' 'https://github.example.invalid/org/repo/pull/1'
EOF
  cat > "$test_root/gitversion" <<'EOF'
#!/usr/bin/env bash
if [[ "$#" != 4 || "$1" != -config || "$2" != .cloudopsworks/gitversion.yaml ||
      "$3" != -showvariable || "$4" != "$TEST_VERSION_VARIABLE" || "$(git rev-parse HEAD)" != "$TEST_HEAD" ]]; then
  printf '%s\n' 'unexpected GitVersion invocation' >&2
  exit 1
fi
printf '%s\n' "$TEST_VERSION_VALUE"
EOF
  chmod +x "$test_root/gh" "$test_root/gitversion"
}

extract_start_guard() {
  local script_dir
  script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  awk '/^START_BASE=\$PRIMARY_BRANCH$/ {inside=1}
    inside && /^```$/ {exit}
    inside {print}' "$script_dir/../cw-release/SKILL.md" > "$test_root/start-guard.sh"
  [[ -s "$test_root/start-guard.sh" ]] || fail 'could not find the Step 3 guard in cw-release'
  bash -n "$test_root/start-guard.sh"
}

start_guard() {
  BRANCH_TYPE="$1" RELEASE_FLOW="$2" PRIMARY_BRANCH="$3" bash "$test_root/start-guard.sh"
}

check_finish() {
  local type=$1 branch=$2 base=$3 remote=$4 body=$5 title=$6
  shift 6
  local local_refs remote_refs gh_args="$test_root/${remote##*/}-$type-gh-args"
  local_refs=$(git show-ref)
  remote_refs=$(git --git-dir="$remote" show-ref)
  GH_ARGS="$gh_args" "$@" "$type" finish --tool-path "gh=$test_root/gh"
  printf '%s\n' pr create --head "$branch" -B "$base" -b "$body" -t "$title" |
    diff -u - "$gh_args" || fail "$type: unexpected PR command"
  [[ "$(git show-ref)" == "$local_refs" && "$(git --git-dir="$remote" show-ref)" == "$remote_refs" &&
     "$(git branch --show-current)" == "$branch" ]] || fail "$type: finish mutated Git refs or checkout"
}

smoke_hotfix() {
  local primary=$1 remote=$2
  shift 2
  local branch=hotfix/v1.3.1 base_head develop_head hotfix_head
  git switch --quiet "$primary"
  base_head=$(git rev-parse "origin/$primary")
  develop_head=$(git --git-dir="$remote" rev-parse develop)
  start_guard hotfix gitflow "$primary"
  TEST_HEAD="$base_head" TEST_VERSION_VARIABLE=MajorMinorPatch TEST_VERSION_VALUE=1.3.0 \
    "$@" hotfix start --tool-path "gitversion=$test_root/gitversion"
  [[ "$(git branch --show-current)" == "$branch" && "$(git rev-parse HEAD)" == "$base_head" ]] ||
    fail 'gitflow hotfix: wrong patch version or base'
  git commit --quiet --allow-empty -m 'fix: smoke hotfix'
  hotfix_head=$(git rev-parse HEAD)
  "$@" hotfix publish
  [[ "$(git --git-dir="$remote" rev-parse "refs/heads/$branch")" == "$hotfix_head" ]] || fail 'gitflow hotfix: wrong published head'
  check_finish hotfix "$branch" "$primary" "$remote" "Hotfix Release $branch, will merge into $primary" \
    "chore: Hotfix Release from $branch" "$@"
  git switch --quiet "$primary"
  git merge --quiet --no-ff "$branch" -m 'chore: merge hotfix' -m '+semver: patch'
  git push --quiet origin "$primary"
  "$@" hotfix purge v1.3.1
  if git show-ref --verify --quiet "refs/heads/$branch" ||
    git --git-dir="$remote" show-ref --verify --quiet "refs/heads/$branch"; then
    fail 'gitflow hotfix: merged branch remains after purge'
  fi
  [[ "$(git --git-dir="$remote" rev-parse develop)" == "$develop_head" ]] || fail 'gitflow hotfix: changed develop'
  printf '%s\n' 'PASS: GitFlow hotfix auto-version, publish, PR-only finish, and merged purge'
}

smoke_feature() (
  local flow=$1
  local primary=stable slug=smoke-release
  local branch="feature/$slug"
  local remote="$test_root/$flow.git"
  local base first_head final_head failure staged unstaged preview tag tag_ref

  init_fixture "$flow" "$primary" "$remote"

  mkdir .cloudopsworks
  {
    printf '# Agents: WayOfWork=%s\n' "$flow"
    printf 'branches:\n  main:\n    regex: ^stable$\n'
    if [[ "$flow" == gitflow ]]; then
      printf '  develop:\n    regex: ^develop$\n'
    fi
  } > .cloudopsworks/gitversion.yaml
  printf 'v1.2.3\n' > .cloudopsworks/_VERSION
  printf 'fixture\n' > fixture.txt
  git add .cloudopsworks fixture.txt
  git commit --quiet -m 'chore: seed implementation repository'
  git push --quiet origin "$primary"
  base=$primary

  if [[ "$flow" == gitflow ]]; then
    git switch --quiet -c develop
    git commit --quiet --allow-empty -m 'chore: seed develop'
    git push --quiet origin develop
    git switch --quiet "$primary"
    base=develop
  fi

  local -a versions=("$tronador_bin" versions --main-branch "$primary" --no-install-tools)
  printf 'staged\n' > fixture.txt
  git add fixture.txt
  printf 'unstaged\n' >> fixture.txt
  staged=$(git diff --cached --binary)
  unstaged=$(git diff --binary)
  if [[ "$flow" == gitflow ]]; then
    if failure=$(start_guard feature "$flow" "$primary" 2>&1); then
      fail "$flow: started on a different base with pending edits"
    fi
    [[ "$failure" == *'STOP: pending edits are not based on the intended release base'* ]] ||
      fail "$flow: did not reach the dirty divergent-base guard: $failure"
    [[ "$(git branch --show-current)" == "$primary" &&
       "$(git diff --cached --binary)" == "$staged" && "$(git diff --binary)" == "$unstaged" ]] ||
      fail "$flow: guard changed the branch or pending edits"
    if git show-ref --verify --quiet "refs/heads/$branch"; then
      fail "$flow: guard created the feature branch"
    fi
    git restore --source=HEAD --staged --worktree -- fixture.txt
    printf '%s\n' 'PASS: Step 3 guard stops dirty GitFlow start on a different develop base'
  fi
  start_guard feature "$flow" "$primary"
  "${versions[@]}" feature start "$slug"
  [[ "$(git branch --show-current)" == "$branch" ]] || fail "$flow: wrong feature branch"
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse "origin/$base")" ]] || fail "$flow: wrong feature base"
  if [[ "$flow" != gitflow ]]; then
    [[ "$(git diff --cached --binary)" == "$staged" && "$(git diff --binary)" == "$unstaged" ]] ||
      fail "$flow: dirty start did not preserve the index and worktree separately"
    printf 'PASS: %s feature start on aligned primary preserves staged and unstaged edits\n' "$flow"
  fi
  git commit --quiet --all --allow-empty -m 'fix: first release change'
  first_head=$(git rev-parse HEAD)
  "${versions[@]}" feature publish
  [[ "$(git rev-parse --abbrev-ref '@{upstream}')" == "origin/$branch" ]] || fail "$flow: wrong upstream"
  [[ "$(git --git-dir="$remote" rev-parse "refs/heads/$branch")" == "$first_head" ]] || fail "$flow: first publish did not reach origin"

  git commit --quiet --allow-empty -m 'fix: second release change'
  final_head=$(git rev-parse HEAD)
  if failure=$(GH_ARGS="$test_root/unpublished-gh-args" "${versions[@]}" feature finish --tool-path "gh=$test_root/gh" 2>&1); then
    fail "$flow: finished a branch that was ahead of origin"
  fi
  [[ "$failure" == *'not exactly published at HEAD'* && ! -e "$test_root/unpublished-gh-args" ]] ||
    fail "$flow: unexpected unpublished finish result: $failure"

  "${versions[@]}" feature publish
  [[ "$(git --git-dir="$remote" rev-parse "refs/heads/$branch")" == "$final_head" ]] || fail "$flow: republish did not reach origin"
  [[ "$(cat .cloudopsworks/_VERSION)" == v1.2.3 ]] || fail "$flow: protected template-generation marker changed"
  [[ ! -e Makefile ]] || fail "$flow: fixture unexpectedly depends on a Makefile"
  [[ -z "$(git status --porcelain)" ]] || fail "$flow: publishing left a dirty worktree"

  if [[ "$flow" == githubflow ]]; then
    export TEST_HEAD="$final_head" TEST_VERSION_VARIABLE=SemVer TEST_VERSION_VALUE=1.3.0-smoke.1
    preview=$("${versions[@]}" tag --dry-run --tool-path "gitversion=$test_root/gitversion")
    [[ "$preview" == *'Calculated GitVersion tag: v1.3.0-smoke.1'* &&
       -z "$(git tag --list)" && -z "$(git --git-dir="$remote" tag --list)" ]] || fail "$flow: incorrect or mutating prerelease preview"
    tag=$("${versions[@]}" tag --publish --tool-path "gitversion=$test_root/gitversion")
    [[ "$tag" == v1.3.0-smoke.1 ]] || fail "$flow: unexpected prerelease tag: $tag"
    tag_ref="refs/tags/$tag"
    [[ "$(git rev-parse "$tag_ref")" == "$(git --git-dir="$remote" rev-parse "$tag_ref")" &&
       "$(git --git-dir="$remote" rev-parse "$tag_ref^{commit}")" == "$final_head" ]] ||
      fail "$flow: published tag does not match the tested branch head"
    printf '%s\n' 'PASS: evaluated and published branch prerelease points at the exact tested head'
  fi

  check_finish feature "$branch" "$base" "$remote" "Feature \"$branch\" finish, will merge into \"$base\"." \
    "chore: Feature Finish from $branch" "${versions[@]}"
  printf 'PASS: %s finish requires exact published head and only creates a stock PR into %s\n' "$flow" "$base"

  if [[ "$flow" != gitflow ]]; then
    if failure=$("${versions[@]}" feature purge "$slug" 2>&1); then
      fail "$flow: purged an unmerged branch"
    fi
    [[ "$failure" == *'not merged into'* ]] || fail "$flow: unexpected purge error: $failure"
    [[ "$(git branch --show-current)" == "$branch" ]] || fail "$flow: failed purge switched branches"
    [[ "$(git --git-dir="$remote" rev-parse "refs/heads/$branch")" == "$final_head" ]] || fail "$flow: failed purge changed origin"
  fi

  # Simulate the already verified merge using the local bare origin only.
  git switch --quiet "$base"
  git merge --quiet --no-ff "$branch" -m 'chore: merge release changes' -m '+semver: patch'
  git push --quiet origin "$base"

  if [[ "$flow" == gitflow ]]; then
    # cw-release terminates at the develop merge and preserves the branch.
    git --git-dir="$remote" show-ref --verify --quiet "refs/heads/$branch" || fail "$flow: feature was not retained"
    git --git-dir="$remote" merge-base --is-ancestor "$final_head" develop || fail "$flow: feature missing from develop"
    if git --git-dir="$remote" merge-base --is-ancestor "$final_head" "$primary"; then
      fail "$flow: feature was merged into primary instead of develop"
    fi
    smoke_hotfix "$primary" "$remote" "${versions[@]}"
  else
    # Exercise guarded CLI cleanup for an already-merged source when permitted.
    "${versions[@]}" feature purge "$slug"
    if git show-ref --verify --quiet "refs/heads/$branch" ||
      git --git-dir="$remote" show-ref --verify --quiet "refs/heads/$branch"; then
      fail "$flow: merged feature remains after purge"
    fi
  fi
  if [[ "$flow" != githubflow ]]; then
    [[ -z "$(git --git-dir="$remote" tag --list)" ]] || fail "$flow: branch delivery created a tag"
  fi
  printf 'PASS: %s feature base, publish, republish, and post-merge branch handling\n' "$flow"
)

smoke_absent_template() (
  local topology=$1
  local primary=stable slug=smoke-release
  local remote="$test_root/absent-template-$topology.git"
  local base_ref="refs/remotes/origin/$primary"
  local branch="feature/$slug" bases head

  # GitHub identity is a precondition checked outside this offline Git test.
  init_fixture "absent-template-$topology" "$primary" "$remote"
  git commit --quiet --allow-empty -m 'chore: seed config-less template'
  git push --quiet origin "$primary"
  if [[ "$topology" == with-develop ]]; then
    git switch --quiet -c develop
    git commit --quiet --allow-empty -m 'chore: seed unrelated develop'
    git push --quiet origin develop
    git switch --quiet "$primary"
  fi
  bases=$(git --git-dir="$remote" for-each-ref "refs/heads/$primary" refs/heads/develop)
  git fetch --quiet origin --prune
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse "$base_ref")" ]] || fail 'config-less template: primary is not in sync'
  git switch --quiet --no-track -c "feature/$slug" "$base_ref"
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse "$base_ref")" ]] || fail 'config-less template: wrong feature base'
  git commit --quiet --allow-empty -m 'fix: smoke config-less template feature'
  head=$(git rev-parse HEAD)
  "$tronador_bin" versions --main-branch "$primary" --no-install-tools feature publish
  [[ "$(git --git-dir="$remote" rev-parse "refs/heads/$branch")" == "$head" ]] ||
    fail 'config-less template: wrong published feature head'
  [[ "$(git --git-dir="$remote" for-each-ref "refs/heads/$primary" refs/heads/develop)" == "$bases" ]] ||
    fail 'config-less template: branch publish changed primary or develop'
  [[ ! -e .cloudopsworks/gitversion.yaml ]] || fail 'config-less template: config was created'
  [[ -z "$(git status --porcelain)" ]] || fail 'config-less template: worktree changed'
  printf 'PASS: config-less template (%s) starts from verified primary and publishes without bootstrapping GitVersion\n' "$topology"
)

init_tool_stubs
extract_start_guard
smoke_feature gitflow
smoke_feature githubflow
smoke_feature trunkbased
smoke_absent_template with-develop
smoke_absent_template without-develop
