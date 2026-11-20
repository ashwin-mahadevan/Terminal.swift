#!/usr/bin/env bash
# Releases the version in VERSION if it isn't out yet: creates the v<version>
# GitHub release and its tag, which is what Swift Package Manager resolves, at
# the commit this is run from, and prints v<version>. When the version is
# already out it does nothing, so it's safe to run again after a failure.
#
# Nothing runs this by itself: whoever merges into master runs it from the
# merged commit, right after the merge. Nobody else runs it, and nobody runs
# `gh release create` or pushes a tag by hand.
set -euo pipefail
cd "$(dirname "$0")"

repo=ashwin-mahadevan/Terminal.swift

# Whether GitHub has something at a path of the repo's API. An answer other
# than "yes" or "not found" (no network, not signed in) stops the release.
exists() {
	local error
	if error="$(gh api "repos/$repo/$1" --silent 2>&1)"; then return 0; fi
	if [[ "$error" == *"HTTP 404"* ]]; then return 1; fi
	echo "$error" >&2
	exit 1
}

version="$(tr -d '[:space:]' < VERSION)"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
	echo "VERSION doesn't hold a version: '$version'" >&2
	exit 1
fi
tag="v$version"

flags=(--generate-notes)
if [[ "$version" == *-* ]]; then flags+=(--prerelease); fi

if exists "git/ref/tags/$tag"; then
	if exists "releases/tags/$tag"; then
		echo "Nothing to release: $tag is already out."
		exit 0
	fi
	# The tag is there without its release: give it one, where it is.
	flags+=(--verify-tag)
else
	flags+=(--target "$(git rev-parse HEAD)")
fi

gh release create "$tag" -R "$repo" "${flags[@]}"
echo "$tag"
