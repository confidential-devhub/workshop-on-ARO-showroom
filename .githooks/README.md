# Git Hooks for Branch Protection

This directory contains git hooks to prevent direct pushes to protected branches locally.

## Installation

Run the installation script:

```bash
./.githooks/install.sh
```

Or manually copy the hook:

```bash
cp .githooks/pre-push .git/hooks/pre-push
chmod +x .git/hooks/pre-push
```

## What it does

The `pre-push` hook prevents you from pushing directly to the `showroom` branch. You should only push to `main`, and the GitHub Actions sync workflow will automatically update `showroom`.

## GitHub Branch Protection (Recommended)

For server-side protection, set up branch protection rules on GitHub:

1. Go to your repository on GitHub
2. Settings → Branches
3. Add rule for `showroom` branch:
   - ✅ Restrict pushes that create files larger than 100 MB
   - ✅ Do not allow bypassing the above settings
   - ⚠️ **Important**: Make sure "Allow specified actors to bypass required pull requests" includes your GitHub Actions bot, or the sync workflow will fail

Alternatively, you can:
- Allow the `sync-branches` workflow to bypass by using a GitHub App or PAT with admin permissions
- Or remove the bypass restriction and ensure the workflow has the necessary permissions

## Bypassing the hook (if needed)

If you absolutely need to push to `showroom` directly (not recommended), you can bypass the hook:

```bash
git push --no-verify origin showroom
# or
git push -n origin showroom
```

**Important notes:**
- `git push -f` (force push) does NOT bypass the hook - it only bypasses server-side fast-forward checks
- `git push --no-verify` or `-n` DOES bypass the hook
- Even if you bypass the hook, GitHub branch protection will still block the push if configured server-side

This is why server-side branch protection is recommended as a second layer of security.

