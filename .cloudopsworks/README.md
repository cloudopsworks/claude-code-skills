# GitVersion Configuration

This repository uses GitVersion to automate semantic versioning following GitHub Flow principles.

## Configuration Details

The `GitVersion.yml` file configures versioning behavior for different branch types:

- **master/main**: Production-ready code, tagged with release versions (v1.2.3)
- **feature branches**: Automatically versioned as alpha releases (v1.2.3-alpha.1)
- **hotfix branches**: Automatically versioned as beta releases (v1.2.3-beta.1)
- **pull requests**: Automatically versioned with PR identifiers (v1.2.3-PullRequest.123)

## GitHub Flow Implementation

In this configuration:
- All features branch directly from master
- All work merges back to master after review
- Releases are handled through tags on master
- There is no develop branch (differentiating from traditional GitFlow)