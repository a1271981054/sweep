#!/usr/bin/env bash
# Install sweep and everything that makes it usable from an agent.
#
#   ./install.sh                      → ~/.local/bin/sweep
#   SWEEP_PREFIX=/usr/local/bin ./install.sh
#
# Installs: the binary, the DSH MCP bundle, and the sweep-clean skill.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"

PREFIX="${SWEEP_PREFIX:-$HOME/.local/bin}"
DEST="$PREFIX/sweep"

# --- 1. binary -------------------------------------------------------------
BIN=""
for candidate in .build/release/sweep .build/apple/Products/Release/sweep bin/sweep; do
  if [ -x "$candidate" ]; then BIN="$candidate"; break; fi
done
if [ -z "$BIN" ]; then
  echo "→ building release (first run compiles MacCleanKit, 1–3 min)…"
  swift build -c release
  BIN=.build/release/sweep
fi

mkdir -p "$PREFIX"
# ditto, not cp: `cp` breaks the linker-signed ad-hoc signature on macOS 26 and
# AMFI kills the copy at exec time ("Unrecoverable CT signature issue").
ditto "$BIN" "$DEST"
chmod +x "$DEST"
echo "✓ binary  $DEST"
"$DEST" version

# --- 2. DSH MCP bundle -----------------------------------------------------
if [ -d "$ROOT/dsh-bundle" ]; then
  TARGET="$HOME/.local/share/sweep/dsh-bundle"
  rm -rf "$TARGET"
  mkdir -p "$TARGET"
  ditto "$ROOT/dsh-bundle" "$TARGET"
  if [ -f "$ROOT/dsh-bundle/cordis.patch.yml.template" ]; then
    sed "s|__SWEEP_BIN__|$DEST|" "$ROOT/dsh-bundle/cordis.patch.yml.template" > "$TARGET/cordis.patch.yml"
  fi
  echo "✓ DSH bundle  $TARGET"
fi

# --- 3. skill --------------------------------------------------------------
if [ -d "$ROOT/skill/sweep-clean" ]; then
  mkdir -p "$HOME/.agents/skills"
  rm -rf "$HOME/.agents/skills/sweep-clean"
  ditto "$ROOT/skill/sweep-clean" "$HOME/.agents/skills/sweep-clean"
  echo "✓ skill  ~/.agents/skills/sweep-clean"
fi

# --- 4. helper (optional, needs one manual permission) ----------------------
if [ "${SWEEP_SKIP_HELPER:-0}" != "1" ]; then
  echo
  echo "→ installing the Full Disk Access helper…"
  if "$DEST" helper-install; then
    echo "  需要手动授权一次（之后四个客户端共用）："
    echo "  系统设置 → 隐私与安全性 → 完全磁盘访问权限 → + →"
    echo "  $HOME/Library/Application Support/SweepHelper/Sweep Helper.app"
  fi
fi

cat <<EOF

下一步：
  1. 看磁盘           $DEST disk
  2. 扫系统垃圾       $DEST scan system-junk
  3. 接入 MCP 客户端  $DEST mcp-config codex    # 或 claude / cursor / dsh / json
  4. 自主度           $DEST mode                # readonly | confirm | auto

DSH 用户：Plugins → Add plugin → 选择 ~/.local/share/sweep/dsh-bundle
然后重启 DSH，工具会以 mcp__sweep__* 出现。

注意：完全磁盘访问权限能扩大扫描范围；没有它时结果里的 deniedPaths 会列出被跳过的路径。
EOF
