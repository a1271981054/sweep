#!/usr/bin/env bash
# Remove upstream branding from the vendored engine's compiled sources.
#
# Only MacCleanKit is compiled into sweep, so only that target is touched.
# The change is mechanical and idempotent: run it again after updating vendor/.
# The modification is permitted by BSD-3 and recorded in NOTICE.md.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="vendor/engine/Sources/MacCleanKit"
[ -d "$TARGET" ] || { echo "missing $TARGET"; exit 1; }

echo "→ scrubbing branding in $TARGET"
python3 - "$TARGET" <<'PY'
import os, sys

root = sys.argv[1]
replacements = [("Mac Sai", "Sweep"), ("MacSai", "Sweep")]
changed = 0
for dirpath, _, filenames in os.walk(root):
    for name in filenames:
        if not name.endswith(".swift"):
            continue
        path = os.path.join(dirpath, name)
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        original = text
        for old, new in replacements:
            text = text.replace(old, new)
        if text != original:
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(text)
            changed += 1
print(f"  {changed} files updated")
PY

echo "→ rebuild to confirm it still compiles"
swift build -c release 2>&1 | tail -1
