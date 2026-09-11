#!/bin/sh
# Render assets/diagrams/*.mmd to *.svg next to them.
# Requires: mermaid-cli (brew install mermaid-cli) + a Chromium browser.
# Default config points at Brave (macOS); override with:
#   PUPPETEER_CONFIG=/path/to/puppeteer.json bash assets/diagrams/render.sh
set -eu
cd "$(dirname "$0")"
CONFIG="${PUPPETEER_CONFIG:-puppeteer.json}"
for src in *.mmd; do
  out="${src%.mmd}.svg"
  echo "render $src -> $out"
  mmdc -i "$src" -o "$out" -p "$CONFIG" --backgroundColor white
done
