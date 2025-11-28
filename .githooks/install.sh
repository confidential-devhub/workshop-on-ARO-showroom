#!/bin/bash

# Install git hooks to prevent direct pushes to protected branches

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"

if [ -z "$REPO_ROOT" ]; then
    echo "Error: Not in a git repository"
    exit 1
fi

# Option 1: Use git's core.hooksPath (recommended - hooks stay in repo)
echo "Setting up git to use hooks from .githooks directory..."
git config core.hooksPath .githooks

# Option 2: Copy hooks to .git/hooks (alternative)
# GIT_DIR="$(git rev-parse --git-dir)"
# HOOKS_TARGET="$GIT_DIR/hooks"
# if [ -f "$HOOKS_DIR/pre-push" ]; then
#     cp "$HOOKS_DIR/pre-push" "$HOOKS_TARGET/pre-push"
#     chmod +x "$HOOKS_TARGET/pre-push"
# fi

# Make sure the hook is executable
chmod +x "$HOOKS_DIR/pre-push"

echo "✅ Git hooks configured!"
echo "   Direct pushes to 'showroom' branch are now blocked locally."
echo ""
echo "To verify, try: git push origin showroom"
echo "(It should be blocked)"

