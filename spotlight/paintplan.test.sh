#!/usr/bin/env bash
# Cases for paintplan.swift. Run: ./spotlight/paintplan.test.sh
#
# Compiled together with paintplan.test.swift into one throwaway binary, run,
# and removed. One file rather than two because Swift allows top-level code
# in only one file of a build — the same reason install.sh joins paintplan.swift
# to ttpaint.swift before compiling the painter.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/paintplan.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
cat "$here/paintplan.swift" "$here/paintplan.test.swift" > "$tmp/cases.swift"
swiftc -O "$tmp/cases.swift" -o "$tmp/cases"
"$tmp/cases"
