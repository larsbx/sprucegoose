#!/usr/bin/env bash
# Install the box-wide git hooks and point core.hooksPath at them.
#
# Idempotent. Run from a checkout:
#   ops/mama-authority/git-hooks/install.sh [dest]     (default ~/.config/git/hooks)
set -euo pipefail

src=$(cd "$(dirname "$0")" && pwd)
dest="${1:-$HOME/.config/git/hooks}"

mkdir -p "$dest/lib"
install -m 644 "$src/lib/hygiene-scan.sh" "$src/lib/doc-gate.sh" "$dest/lib/"
install -m 755 "$src/_chain" "$src/pre-commit" "$src/commit-msg" "$dest/"

# Every other standard hook name becomes a passthrough, because core.hooksPath
# REPLACES a repo's hooks directory rather than merging with it. Deliberately
# excluded: reference-transaction, pre-auto-gc and fsmonitor-watchman — they
# fire often enough that a subprocess per invocation is a real cost, and
# nothing on this box defines them.
for h in applypatch-msg pre-applypatch post-applypatch pre-merge-commit \
         prepare-commit-msg post-commit pre-rebase post-checkout post-merge \
         pre-push pre-receive update proc-receive post-receive post-update \
         push-to-checkout post-rewrite sendemail-validate; do
  ln -sfn _chain "$dest/$h"
done

git config --global core.hooksPath "$dest"

# Belt and braces for the one hook whose failure would be silent and costly:
# ~/agent-icm.git's post-receive mirrors main and its tags to Forgejo. The
# _chain passthrough already covers it; this pins it locally as well so a
# future edit to the global path cannot take publication down.
if [ -d "$HOME/agent-icm.git/hooks" ]; then
  git -C "$HOME/agent-icm.git" config core.hooksPath "$HOME/agent-icm.git/hooks"
fi

echo "installed to $dest"
echo "core.hooksPath (global) = $(git config --global --get core.hooksPath)"
