#!/usr/bin/env bash
# Runs every check a change has to pass: run it before the change is merged. No
# GitHub workflow checks a change. The checks run one at a time, and a failure
# doesn't stop the ones after it. The last lines say which passed and which
# failed, and the exit status is non-zero if any failed.
set -u
cd "$(dirname "$0")"

checks=(
	"swift test"
	# Compiles the UIKit code, which the tests (on macOS) don't.
	"xcodebuild -scheme Terminal.swift -destination 'generic/platform=iOS Simulator' -derivedDataPath build build"
)

results=()
failed=0
for check in "${checks[@]}"; do
	echo "==> $check"
	if bash -c "$check"; then
		results+=("passed: $check")
	else
		results+=("FAILED: $check")
		failed=1
	fi
done

echo
printf '%s\n' "${results[@]}"
exit "$failed"
