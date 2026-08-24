#!/bin/bash
# Runs the tests. Lives outside Sources/, so SwiftPM does not build them into the app.
# The tests work in a temporary folder of their own and leave your real settings alone.
set -euo pipefail
cd "$(dirname "$0")"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

# The string catalogue next to the binary. Bundle.main of a plain command-line tool is the
# folder the executable sits in, so copying the .lproj folders there is enough to make the
# lookups resolve -- without the test having to know anything about SwiftPM's bundle.
cp -R Sources/Presort/Resources/*.lproj "$OUT/"

swiftc -o "$OUT/proef" \
    Sources/Presort/Herkenners.swift \
    Sources/Presort/Wachtrij.swift \
    Proef/main.swift
"$OUT/proef"
