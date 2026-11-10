#!/bin/bash
# Bumps VERSION, commits it and tags the commit, ready for `git push --follow-tags`:
#   Scripts/version.sh patch     0.4.0 → 0.4.1
#   Scripts/version.sh minor     0.4.1 → 0.5.0
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first." >&2; exit 1; }
IFS=. read -r major minor patch < VERSION
case "${1:-}" in
    patch) patch=$((patch + 1)) ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    major) major=$((major + 1)); minor=0; patch=0 ;;
    *) echo "Usage: Scripts/version.sh patch|minor|major" >&2; exit 2 ;;
esac
next="$major.$minor.$patch"
echo "$next" > VERSION
git commit -q -m "$next" VERSION
git tag -a "v$next" -m "$next"
echo "Tagged v$next. Push it with: git push --follow-tags"
