#!/usr/bin/env bash
# Install (or refresh) the global `brg` command for the human.
#
#   From a clone:  bash install.sh [target_dir]          (default: ~/.local/bin)
#   One line:      curl -fsSL https://raw.githubusercontent.com/asavochkin/brigada/master/install.sh | bash
#                  ... | bash -s -- /usr/local/bin       (another target_dir)
#
# Without a clone next to it (a pipe, or the file downloaded alone) the script clones the repo
# to $BRIGADA_DIR (default ~/.local/share/brigada) from $BRIGADA_REPO — an existing clone is
# updated with `git pull --ff-only` — and runs the install.sh of that clone. Re-running = update.
# Re-run after moving the clone or changing bin/brg-global.
#
# Everything is in functions and `main "$@"` is the LAST line: a script read from a pipe is
# consumed by whatever reads stdin (git would eat the rest of it), and a half-downloaded script
# must run nothing.
if [ -z "${BASH_VERSION:-}" ]; then # sh/dash: no BASH_SOURCE, a clone would look absent
  echo "── ОШИБКА: запусти через bash: bash install.sh или curl … | bash" >&2
  exit 1
fi
set -eu

# the file this script is read from; empty from a pipe, -s, -c. At the top level, with :- —
# bash 3.2 has no BASH_SOURCE there under `curl | bash` and `set -u` would fail on [0]. $0 is
# never used: it is "bash" there, which would mean the current directory.
src=${BASH_SOURCE:-}

die() {
  echo "── ОШИБКА: $*" >&2
  exit 1
}

# abs_v VAR — make the path in VAR absolute (no cd: the directory may not exist yet)
abs_v() {
  local v
  eval "v=\${$1}"
  case $v in
    /* | [A-Za-z]:[/\\]*) ;;
    *) v=$PWD/$v ;;
  esac
  [ "$v" = / ] || v=${v%/}
  eval "$1=\$v"
}

# From a clone: write the command into target_dir.
install_here() { # HOME_DIR [target_dir]
  local home_dir=$1 target tmp line was= nl found=
  nl='
'
  target=${2:-}
  if [ -z "$target" ]; then
    [ -n "${HOME:-}" ] || die "не задан HOME — укажи каталог установки аргументом: bash install.sh <каталог>"
    target=$HOME/.local/bin
  fi
  abs_v target
  # the path goes into a double-quoted string of the command: anything the shell would expand
  # there would be expanded at every run of brg
  case $home_dir in
    *'"'* | *'$'* | *'`'* | *'\'* | *"$nl"*)
      die "в пути $home_dir есть символ \" \$ \` \\ или перевод строки — он ломает команду brg; перенеси brigada в другой каталог (BRIGADA_DIR=…)"
      ;;
  esac
  mkdir -p "$target" || die "не удалось создать $target"
  if [ -f "$target/brg" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case $line in
        'BRIGADA_HOME="'*'"')
          was=${line#BRIGADA_HOME=\"}
          was=${was%\"}
          break
          ;;
      esac
    done <"$target/brg"
  fi
  tmp="$target/.brg.$$"
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = 'BRIGADA_HOME="@BRIGADA_HOME@"' ]; then
      printf 'BRIGADA_HOME="%s"\n' "$home_dir"
      found=1
    else
      printf '%s\n' "$line"
    fi
  done <"$home_dir/bin/brg-global" >"$tmp"
  if [ -z "$found" ]; then
    rm -f "$tmp"
    die "в $home_dir/bin/brg-global нет строки BRIGADA_HOME=\"@BRIGADA_HOME@\""
  fi
  if ! { chmod 755 "$tmp" && mv -f "$tmp" "$target/brg"; }; then
    rm -f "$tmp"
    die "не удалось записать $target/brg"
  fi

  echo "── установлено: $target/brg → $home_dir"
  if [ -n "$was" ] && [ "$was" != "$home_dir" ]; then
    echo "── было: $was → стало: $home_dir"
  fi
  case ":$PATH:" in
    *":$target:"*) echo "── $target уже в PATH: команда brg доступна" ;;
    *) echo "── добавь в PATH: export PATH=\"$target:\$PATH\"" ;;
  esac
}

# No clone next to the script: clone or update one, then install from it.
fetch_clone() { # [target_dir]
  local repo dir
  [ -z "${BRIGADA_INSTALL_FROM_CLONE:-}" ] || die "в клоне нет install.sh с каталогом bin/ рядом — это не репозиторий brigada"
  # git first: before any other external command (a git-less PATH must give this message).
  # --version, not command -v: on a Mac without Command Line Tools /usr/bin/git is a stub
  git --version >/dev/null 2>&1 </dev/null || die "нужен git (macOS: xcode-select --install). Или вручную: скачай репозиторий и запусти bash install.sh из него"
  repo=${BRIGADA_REPO:-https://github.com/asavochkin/brigada.git}
  if [ -n "${BRIGADA_DIR:-}" ]; then
    dir=$BRIGADA_DIR
  else
    [ -n "${HOME:-}" ] || die "не задан HOME — укажи BRIGADA_DIR=<каталог для клона>"
    dir=$HOME/.local/share/brigada
  fi
  abs_v dir
  export GIT_TERMINAL_PROMPT=0 # a wrong BRIGADA_REPO must not ask for a login on the tty
  if [ -e "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
    if [ -e "$dir/.git" ] && [ -f "$dir/bin/brg-global" ] && [ -f "$dir/install.sh" ]; then
      if ! git -C "$dir" pull --ff-only </dev/null; then
        die "не удалось обновить $dir (git pull --ff-only; правки в клоне или переписанная история?) — обнови вручную: git -C $dir pull"
      fi
      echo "── brigada: обновлено $dir (git pull)"
    else
      die "$dir уже есть, но это не клон brigada — ничего не трогаю. Другой каталог: BRIGADA_DIR=<каталог> (клонируется туда)"
    fi
  else
    git clone --depth 1 -q "$repo" "$dir" </dev/null || die "не удалось клонировать $repo в $dir"
    echo "── brigada: клонировано в $dir"
  fi
  [ -f "$dir/install.sh" ] && [ -f "$dir/bin/brg-global" ] && [ -f "$dir/bin/brg" ] || die "в $dir нет install.sh и bin/ — это не репозиторий brigada"
  BRIGADA_INSTALL_FROM_CLONE=1 exec bash "$dir/install.sh" "$@" </dev/null
}

main() {
  local here
  if [ -n "$src" ] && [ -f "$src" ]; then
    case $src in */*) here=${src%/*} ;; *) here=. ;; esac
    here=$(CDPATH= cd -- "$here" && pwd) || die "не удалось открыть каталог $here"
    if [ -f "$here/bin/brg-global" ] && [ -f "$here/bin/brg" ]; then
      install_here "$here" "$@"
      return 0
    fi
  fi
  fetch_clone "$@"
}

main "$@"
