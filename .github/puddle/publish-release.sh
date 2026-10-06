#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# publish-release.sh - create the fork release for a v<release>-puddle.N tag (fork-only file).
#
# usage: publish-release.sh <tag> <upstream repo> <upstream tag> <run url> <dir with msb-windows-x86_64.exe>
#        <dir with upstream libkrunfw-windows-x86_64.dll + agentd-x86_64> [extra notes file]
# Needs GH_TOKEN with contents: write and GITHUB_REPOSITORY. Never overwrites an existing release.
set -euo pipefail
tag=$1 up_repo=$2 up_tag=$3 run_url=$4 msb_dir=$5 up_dir=$6 extra=${7:-}
if gh release view "$tag" -R "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
  echo "::error::release $tag already exists; not overwriting its assets"
  exit 1
fi
a=$(mktemp -d)
cp "$msb_dir/msb-windows-x86_64.exe" "$up_dir/libkrunfw-windows-x86_64.dll" "$up_dir/agentd-x86_64" "$a/"
(cd "$a" && sha256sum msb-windows-x86_64.exe libkrunfw-windows-x86_64.dll agentd-x86_64 > checksums.sha256 && cat checksums.sha256)
{
  echo "puddle fork of microsandbox at \`$tag\`: upstream [\`$up_tag\`](https://github.com/$up_repo/releases/tag/$up_tag) plus the puddle patch stack (see the commits on top of \`$up_tag\`)."
  echo
  echo "- \`msb-windows-x86_64.exe\`: built by [this run]($run_url) with MSVC, static CRT, features \`embed-binaries,net,ssh\`, embedding upstream's agentd."
  echo "- \`libkrunfw-windows-x86_64.dll\`, \`agentd-x86_64\`: unchanged from upstream \`$up_tag\`, checked against its \`checksums.sha256\`."
  echo "- \`checksums.sha256\`: SHA-256 of the three files above."
  if [ -n "$extra" ] && [ -f "$extra" ]; then echo; cat "$extra"; fi
  echo
  echo "Not an official microsandbox release."
} > "$a/notes.md"
gh release create "$tag" -R "$GITHUB_REPOSITORY" --verify-tag --title "$tag" --notes-file "$a/notes.md" \
  "$a/msb-windows-x86_64.exe" "$a/libkrunfw-windows-x86_64.dll" "$a/agentd-x86_64" "$a/checksums.sha256"
