#!/usr/bin/env bash
# Build a distributable tarball: universal binary + installer + bundle + skill.
#
#   ./scripts/package.sh
#   → dist/sweep-<version>-macos-universal.tar.gz (+ .sha256)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

VERSION=$(grep -o 'sweep [0-9][0-9.]*' Sources/SweepAgent/CLI.swift | head -1 | awk '{print $2}')
VERSION="${VERSION:-0.0.0}"
NAME="sweep-${VERSION}-macos-universal"
STAGE="dist/${NAME}"

echo "→ building universal binary (arm64 + x86_64)…"
swift build -c release --arch arm64 --arch x86_64
BIN=".build/apple/Products/Release/sweep"
[ -x "$BIN" ] || { echo "universal build missing: $BIN"; exit 1; }
lipo -archs "$BIN" | grep -q "arm64" && lipo -archs "$BIN" | grep -q "x86_64" \
  || { echo "not universal: $(lipo -archs "$BIN")"; exit 1; }

rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/skill"
ditto "$BIN" "$STAGE/bin/sweep"
chmod +x "$STAGE/bin/sweep"

ditto install.sh "$STAGE/install.sh"
chmod +x "$STAGE/install.sh"
ditto README.md "$STAGE/README.md"
ditto dsh-bundle "$STAGE/dsh-bundle"
if [ -d "$HOME/.agents/skills/sweep-clean" ]; then
  ditto "$HOME/.agents/skills/sweep-clean" "$STAGE/skill/sweep-clean"
fi

(
  cd "$STAGE"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 shasum -a 256 > SHA256SUMS
)
tar -czf "dist/${NAME}.tar.gz" -C dist "$NAME"
shasum -a 256 "dist/${NAME}.tar.gz" > "dist/${NAME}.tar.gz.sha256"

echo
echo "✓ dist/${NAME}.tar.gz  ($(du -h "dist/${NAME}.tar.gz" | awk '{print $1}'))"
echo "✓ dist/${NAME}.tar.gz.sha256"
echo
echo "别人拿到后："
echo "  tar xzf ${NAME}.tar.gz && cd ${NAME} && ./install.sh"
