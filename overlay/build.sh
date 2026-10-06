#!/usr/bin/env bash
# Build the overlay. Writes to a fresh path and moves it into place: overwriting a signed
# Mach-O in place makes macOS SIGKILL it on next launch (stale code-signature cache).
set -euo pipefail
cd "$(dirname "$0")"
swiftc -O main.swift -o agent-overlay-mac.new
rm -f agent-overlay-mac
mv agent-overlay-mac.new agent-overlay-mac
echo "built $(pwd)/agent-overlay-mac"
