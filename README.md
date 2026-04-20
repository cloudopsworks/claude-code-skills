# CloudOps Works Claude Code Skills

Claude Code skills for CloudOps Works Terraform module gitflow workflows.

## Skills

| Skill | Description |
|-------|-------------|
| [`cw-release`](./cw-release/SKILL.md) | Full gitflow release workflow for Terraform modules (feature, hotfix, PR, merge, tag, publish) |

## Installation

Copy the desired skill directory into your Claude Code skills folder:

```bash
# Clone the repo
git clone https://github.com/cloudopsworks/claude-code-skills.git

# Copy the skill(s) you need
cp -r claude-code-skills/cw-release ~/.claude/skills/
```

Or symlink to keep the skill up to date with the repo:

```bash
git clone https://github.com/cloudopsworks/claude-code-skills.git ~/cloudopsworks/claude-code-skills
ln -s ~/cloudopsworks/claude-code-skills/cw-release ~/.claude/skills/cw-release
```

## Usage

Once installed, invoke the skill in Claude Code:

```
/cw-release
```

See each skill's `SKILL.md` for full documentation.

## Contributing

Skills follow the CloudOps Works gitflow contribution model. See [AGENTS.md](./AGENTS.md) if present, or submit a PR against `develop`.
