#!/bin/bash
# Draait de proeven. Staat buiten Sources/, zodat SwiftPM ze niet meebouwt in de app.
# De proeven werken in een eigen tijdelijke map en laten je echte instellingen met rust.
set -euo pipefail
cd "$(dirname "$0")"
UIT=$(mktemp -d)
trap 'rm -rf "$UIT"' EXIT
swiftc -o "$UIT/proef" \
    Sources/Presort/Herkenners.swift \
    Sources/Presort/Wachtrij.swift \
    Proef/main.swift
"$UIT/proef"
