#!/usr/bin/env bash
# Install (or refresh) the global `brg` command for the human.
# Usage: bash install.sh [target_dir]   (default: ~/.local/bin)
# Re-run after moving the repo or changing bin/brg-global.
set -eu

case ${BASH_SOURCE[0]} in */*) HERE=${BASH_SOURCE[0]%/*} ;; *) HERE=. ;; esac
HOME_DIR=$(cd "$HERE" && pwd)
TARGET=${1:-$HOME/.local/bin}

mkdir -p "$TARGET"
tmp="$TARGET/.brg.$$"
sed "s#@BRIGADA_HOME@#$HOME_DIR#" "$HOME_DIR/bin/brg-global" > "$tmp"
chmod 755 "$tmp"
mv -f "$tmp" "$TARGET/brg"

echo "── установлено: $TARGET/brg → $HOME_DIR"
case ":$PATH:" in
  *":$TARGET:"*) echo "── $TARGET уже в PATH: команда brg доступна" ;;
  *) echo "── добавь в PATH: export PATH=\"$TARGET:\$PATH\"" ;;
esac
