#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# pin-pr.sh - open the pin-bump PR in the puddle product repo for a new fork tag (fork-only file).
#
# usage: PIN_TOKEN=... pin-pr.sh <new version, e.g. 0.7.8-puddle.1> <release url>
# PIN_TOKEN: fine-grained token for TijsVK/puddle only (Contents + Pull requests read/write), secret
# PUDDLE_PIN_TOKEN (puddle D-60). Changes on a branch off `develop`: BUILT_FOR in
# crates/puddle-runtime/src/version.rs, and every `v<old>` / `=<old>` fork pin in the root Cargo.toml
# (Cargo.lock refreshed). The PR says to run ci/windows-e2e.ps1 on the laptop before merging: adopting
# a fork tag stays a deliberate step.
set -euo pipefail
new=$1 release_url=$2
repo=TijsVK/puddle
w=$(mktemp -d)
git clone -q --depth 1 --branch develop "https://x-access-token:${PIN_TOKEN}@github.com/$repo.git" "$w/puddle"
cd "$w/puddle"
f=crates/puddle-runtime/src/version.rs
old=$(sed -n 's/^pub const BUILT_FOR: &str = "\(.*\)";$/\1/p' "$f")
[ -n "$old" ] || { echo "::error::no BUILT_FOR in $f"; exit 1; }
if [ "$old" = "$new" ]; then echo "puddle already pins $new"; exit 0; fi
branch="fork-pin/v$new"
if git ls-remote --exit-code origin "refs/heads/$branch" >/dev/null; then echo "branch $branch exists; not touching it"; exit 0; fi
git checkout -q -b "$branch"
sed -i "s/^pub const BUILT_FOR: &str = \"$old\";$/pub const BUILT_FOR: \&str = \"$new\";/" "$f"
sed -i -e "s/\"v$old\"/\"v$new\"/g" -e "s/\"=$old\"/\"=$new\"/g" Cargo.toml
if ! git diff --quiet -- Cargo.toml; then cargo metadata --format-version 1 >/dev/null; fi
git -c user.name="puddle auto-bump" -c user.email=puddle@tijsvankampen.be commit -q -am "build: bundle msb fork $new (was $old)

Moves BUILT_FOR and the fork pins in Cargo.toml to v$new: $release_url.
Opened by the msb fork's auto-bump job."
git push -q origin "$branch"
GH_TOKEN=$PIN_TOKEN gh pr create -R "$repo" --base develop --head "$branch" \
  --title "build: bundle msb fork $new" \
  --body "The msb fork published [v$new]($release_url) (all fork gates green). This moves BUILT_FOR and the fork pins from $old.

Before merging: CI green, then run \`ci/windows-e2e.ps1\` on the laptop (W7: before every msb bump), and \`cargo xtask runtime --tag v$new\`.

Opened by TijsVK/microsandbox's puddle-autobump workflow."
