#!/usr/bin/env bash
# Copy the interface from the repo to the directory the helper serves, so visual
# changes show up on refresh without rebuilding (a rebuild costs a permission
# grant).
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="$HOME/.local/share/sweep/web"
mkdir -p "$TARGET"
rm -rf "$TARGET"/*
ditto web/* "$TARGET"/

echo "→ $TARGET"
ls "$TARGET" | sed 's/^/  /'
curl -s -o /dev/null -w "  http://127.0.0.1:47901/ → %{http_code}\n" --max-time 3 http://127.0.0.1:47901/ || true
