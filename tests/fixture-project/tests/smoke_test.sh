#!/bin/sh
# Fixture test: the page and the health file are what the release ships.
set -eu
cd "$(dirname "$0")/.."
grep -q '<h1>fixture-app</h1>' src/index.html || { echo "FAIL: page heading"; exit 1; }
[ "$(cat src/health)" = "ok" ] || { echo "FAIL: health body"; exit 1; }
echo "PASS: smoke_test"
