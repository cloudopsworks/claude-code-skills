#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

usage() {
  cat <<'EOF'
Install CloudOps Works skills into Claude Code, OpenCode, and/or Codex.

Usage:
  install-cloudopsworks-skills.sh [--skill <name|all>]... [--target claude|opencode|codex|all] [--mode copy|symlink] [--force]

Options:
  --skill    Skill to install. Repeatable. Use 'all' to install every discovered skill.
             Default: all
  --target   Installation target. Default: all
  --mode     Install mode for directory-based targets. Default: symlink
             OpenCode always generates command files.
  --force    Replace an existing installation.
  --help     Show this help.
EOF
}

TARGET="all"
MODE="symlink"
FORCE=0
REQUESTED_SKILLS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skill)
      REQUESTED_SKILLS+=("${2:-}")
      shift 2
      ;;
    --target)
      TARGET="${2:-}"
      shift 2
      ;;
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "$TARGET" in
  claude|opencode|codex|all) ;;
  *) echo "Invalid --target: $TARGET" >&2; exit 1 ;;
esac

case "$MODE" in
  copy|symlink) ;;
  *) echo "Invalid --mode: $MODE" >&2; exit 1 ;;
esac

mapfile -t DISCOVERED_SKILLS < <(
  find "$REPO_ROOT" -mindepth 2 -maxdepth 2 -name SKILL.md -print \
    | sed "s#^$REPO_ROOT/##" \
    | sed 's#/SKILL\.md$##' \
    | sort
)

if [[ ${#DISCOVERED_SKILLS[@]} -eq 0 ]]; then
  echo "No skills found under $REPO_ROOT" >&2
  exit 1
fi

if [[ ${#REQUESTED_SKILLS[@]} -eq 0 ]]; then
  REQUESTED_SKILLS=(all)
fi

contains_skill() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

SKILLS=()
if contains_skill all "${REQUESTED_SKILLS[@]}"; then
  SKILLS=("${DISCOVERED_SKILLS[@]}")
else
  for skill in "${REQUESTED_SKILLS[@]}"; do
    if contains_skill "$skill" "${DISCOVERED_SKILLS[@]}"; then
      SKILLS+=("$skill")
    else
      echo "Unknown skill: $skill" >&2
      echo "Discovered skills: ${DISCOVERED_SKILLS[*]}" >&2
      exit 1
    fi
  done
fi

HOME_DIR=${HOME:-$(cd ~ && pwd)}
CLAUDE_SKILLS_DIR="${CLAUDE_CODE_HOME:-$HOME_DIR/.claude}/skills"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME_DIR/.codex}"
CODEX_SKILLS_DIR="$CODEX_HOME_DIR/skills"
OPENCODE_HOME_DIR="${OPENCODE_HOME:-$HOME_DIR/.config/opencode}"
OPENCODE_COMMANDS_DIR="$OPENCODE_HOME_DIR/commands"

remove_if_force() {
  local path="$1"
  if [[ -e "$path" || -L "$path" ]]; then
    if [[ "$FORCE" -eq 1 ]]; then
      rm -rf "$path"
    else
      echo "Target already exists: $path" >&2
      echo "Re-run with --force to replace it." >&2
      exit 1
    fi
  fi
}

skill_source_dir() {
  local skill="$1"
  printf '%s/%s' "$REPO_ROOT" "$skill"
}

skill_source_file() {
  local skill="$1"
  printf '%s/SKILL.md' "$(skill_source_dir "$skill")"
}

skill_description() {
  local skill_file="$1"
  awk '
    BEGIN { in_front=0; in_desc=0 }
    /^---[[:space:]]*$/ {
      if (in_front == 0) { in_front=1; next }
      if (in_front == 1) { exit }
    }
    in_front == 1 {
      if ($0 ~ /^description:[[:space:]]*\|[[:space:]]*$/) { in_desc=1; next }
      if (in_desc == 1) {
        if ($0 ~ /^[-A-Za-z0-9_]+:[[:space:]]*/) exit
        sub(/^  /, "")
        print
        next
      }
      if ($0 ~ /^description:[[:space:]]*/) {
        sub(/^description:[[:space:]]*/, "")
        print
        exit
      }
    }
  ' "$skill_file" | paste -sd ' ' - | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//'
}

install_dir_target() {
  local skill="$1"
  local target_root="$2"
  local src_dir target_path
  src_dir=$(skill_source_dir "$skill")
  target_path="$target_root/$skill"

  mkdir -p "$target_root"
  remove_if_force "$target_path"

  if [[ "$MODE" == "symlink" ]]; then
    ln -s "$src_dir" "$target_path"
    printf 'Installed %s -> %s (symlink)\n' "$skill" "$target_path"
  else
    cp -R "$src_dir" "$target_path"
    printf 'Installed %s -> %s (copy)\n' "$skill" "$target_path"
  fi
}

generate_opencode_command() {
  local skill="$1"
  local target_file="$2"
  local skill_file tmp_body description
  skill_file=$(skill_source_file "$skill")
  description=$(skill_description "$skill_file")
  tmp_body=$(mktemp)

  awk 'BEGIN{front=0} /^---[[:space:]]*$/{front++; next} front>=2{print}' "$skill_file" > "$tmp_body"

  mkdir -p "$(dirname "$target_file")"

  cat > "$target_file" <<EOF
---
name: $skill
description: |
  ${description:-CloudOps Works skill}
permissions:
  read: true
  write: true
  bash: true
  glob: true
  grep: true
  question: true
---

<objective>
Execute the CloudOps Works $skill workflow from the installed skill source.
This OpenCode command is generated from $skill_file.
</objective>

<process>
EOF

  cat "$tmp_body" >> "$target_file"
  printf '\n</process>\n' >> "$target_file"
  rm -f "$tmp_body"

  printf 'Installed %s -> %s (generated command)\n' "$skill" "$target_file"
}

install_opencode() {
  local skill="$1"
  local command_dir="$OPENCODE_COMMANDS_DIR/$skill"
  local target_file="$command_dir/$skill.md"
  remove_if_force "$command_dir"
  generate_opencode_command "$skill" "$target_file"
}

for skill in "${SKILLS[@]}"; do
  [[ -f "$(skill_source_file "$skill")" ]] || { echo "Missing source skill file for $skill" >&2; exit 1; }

  if [[ "$TARGET" == "claude" || "$TARGET" == "all" ]]; then
    install_dir_target "$skill" "$CLAUDE_SKILLS_DIR"
  fi

  if [[ "$TARGET" == "codex" || "$TARGET" == "all" ]]; then
    install_dir_target "$skill" "$CODEX_SKILLS_DIR"
  fi

  if [[ "$TARGET" == "opencode" || "$TARGET" == "all" ]]; then
    install_opencode "$skill"
  fi
done
