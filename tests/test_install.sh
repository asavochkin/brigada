# install.sh: the two modes (from a clone; from a pipe — clone or update the repo in
# BRIGADA_DIR and install from it). No network: the source is a temporary local repository
# (file://, from the working tree), HOME is a temporary directory, the target is always an
# argument. Needs git (the tests are skipped without it).

GITC="-c user.name=t -c user.email=t@t"

inst_need() {
  git --version >/dev/null 2>&1 || {
    echo "SKIP: no git"
    return 1
  }
  export GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
  T0=$(mk_tmpdir)
  HOME=$(mk_tmpdir)
  export HOME
  unset BRIGADA_REPO BRIGADA_DIR BRIGADA_INSTALL_FROM_CLONE
}

# mk_src — a repository with install.sh, bin/brg, bin/brg-global of the working tree; sets SRC
mk_src() {
  SRC=$(mk_tmpdir)
  mkdir "$SRC/bin"
  cp "$ROOT/install.sh" "$SRC/"
  cp "$ROOT/bin/brg" "$ROOT/bin/brg-global" "$SRC/bin/"
  git -C "$SRC" init -q 2>/dev/null
  git -C "$SRC" add -A
  git -C "$SRC" $GITC commit -qm one || fail "commit in the source"
}

# pipe_install [args…] — cat install.sh | bash -s -- args…, from PIPE_CWD (default: an empty
# directory); sets OUT RC
pipe_install() {
  OUT=$(cat "$ROOT/install.sh" | (cd "${PIPE_CWD:-$T0}" && /bin/bash -s -- "$@") 2>&1)
  RC=$?
}

test_install_pipe_clone_then_update() {
  local clone tgt v
  inst_need || return 0
  mk_src
  clone=$T0/clone
  tgt=$T0/bin
  export BRIGADA_REPO=file://$SRC BRIGADA_DIR=$clone
  pipe_install "$tgt"
  assert_eq 0 "$RC" "install from a pipe:
$OUT"
  assert_contains "$OUT" "── brigada: клонировано в $clone"
  assert_contains "$OUT" "── установлено: $tgt/brg → $clone"
  assert_file_exists "$clone/.git"
  assert_contains "$(cat "$tgt/brg")" "BRIGADA_HOME=\"$clone\""
  assert_not_contains "$(cat "$tgt/brg")" "@BRIGADA_HOME@"
  v=$(cd "$T0" && "$tgt/brg" --version) || fail "brg --version"
  assert_contains "$v" "brg "
  # a pipe leaves nothing in HOME (the target and the clone were arguments)
  assert_eq "" "$(ls -A "$HOME")" "HOME untouched"
  # a new commit in the source: the same line updates the clone
  echo "extra" >"$SRC/NEW"
  git -C "$SRC" add -A
  git -C "$SRC" $GITC commit -qm two || fail "commit two"
  pipe_install "$tgt"
  assert_eq 0 "$RC" "update:
$OUT"
  assert_contains "$OUT" "── brigada: обновлено $clone (git pull)"
  assert_not_contains "$OUT" "клонировано"
  assert_file_exists "$clone/NEW" "the clone got the new commit"
  assert_eq "$(git -C "$SRC" rev-parse HEAD)" "$(git -C "$clone" rev-parse HEAD)"
}

test_install_other_home_is_told() {
  local tgt
  inst_need || return 0
  mk_src
  tgt=$T0/bin
  # the command points at a working clone; the one-liner moves it and says so
  bash "$SRC/install.sh" "$tgt" >/dev/null || fail "install from the clone"
  export BRIGADA_REPO=file://$SRC BRIGADA_DIR=$T0/clone
  pipe_install "$tgt"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "── было: $SRC → стало: $T0/clone"
  # the same home again: no such line
  pipe_install "$tgt"
  assert_not_contains "$OUT" "── было:"
}

test_install_pipe_refuses_foreign_dir() {
  local d
  inst_need || return 0
  mk_src
  d=$T0/mine
  mkdir "$d"
  echo "my file" >"$d/data.txt"
  export BRIGADA_REPO=file://$SRC BRIGADA_DIR=$d
  pipe_install "$T0/bin"
  [ "$RC" != 0 ] || fail "a foreign non-empty directory was accepted:
$OUT"
  assert_contains "$OUT" "не клон brigada"
  assert_contains "$OUT" "BRIGADA_DIR"
  assert_eq "my file" "$(cat "$d/data.txt")" "the directory is untouched"
  assert_eq "data.txt" "$(ls -A "$d")" "nothing was added to it"
  assert_file_not_exists "$T0/bin/brg"
  # a git repository that is not brigada
  git -C "$d" init -q 2>/dev/null
  pipe_install "$T0/bin"
  [ "$RC" != 0 ] || fail "a foreign repository was accepted"
  assert_contains "$OUT" "не клон brigada"
  # an empty existing directory is fine
  d=$T0/empty
  mkdir "$d"
  export BRIGADA_DIR=$d
  pipe_install "$T0/bin"
  assert_eq 0 "$RC" "$OUT"
  assert_file_exists "$d/bin/brg-global"
  # the repository without install.sh / bin/ is not brigada
  git -C "$SRC" rm -q -r bin
  git -C "$SRC" $GITC commit -qm nobin || fail commit
  export BRIGADA_DIR=$T0/other
  pipe_install "$T0/bin2"
  [ "$RC" != 0 ] || fail "a repository without bin/ was accepted"
  assert_contains "$OUT" "это не репозиторий brigada"
  assert_file_not_exists "$T0/bin2/brg"
}

test_install_pipe_without_git() {
  local e
  inst_need || return 0
  mk_src
  e=$(mk_tmpdir) # an empty directory as PATH: no git, and nothing else either
  export BRIGADA_REPO=file://$SRC BRIGADA_DIR=$T0/clone
  OUT=$(cat "$ROOT/install.sh" | (cd "$T0" && PATH=$e /bin/bash -s -- "$T0/bin") 2>&1)
  RC=$?
  [ "$RC" != 0 ] || fail "no git, but exit 0"
  assert_contains "$OUT" "нужен git"
  assert_file_not_exists "$T0/clone"
  assert_file_not_exists "$T0/bin/brg"
}

# a pipe run from a directory that has bin/brg-global (a clone!) must not install from the cwd
test_install_pipe_in_a_clone_dir_still_clones() {
  inst_need || return 0
  mk_src
  export BRIGADA_REPO=file://$SRC BRIGADA_DIR=$T0/clone
  PIPE_CWD=$SRC pipe_install "$T0/bin"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "── brigada: клонировано в $T0/clone"
  assert_contains "$(cat "$T0/bin/brg")" "BRIGADA_HOME=\"$T0/clone\""
  # not an infinite loop and not a foreign repo: from a clone without install.sh/bin — an error
  OUT=$(cat "$ROOT/install.sh" | (cd "$T0" && BRIGADA_INSTALL_FROM_CLONE=1 /bin/bash -s -- "$T0/bin3") 2>&1)
  [ $? != 0 ] || fail "the guard against a second clone did not work"
  assert_file_not_exists "$T0/bin3/brg"
}

test_install_pull_refused_keeps_local_changes() {
  local clone
  inst_need || return 0
  mk_src
  clone=$T0/clone
  export BRIGADA_REPO=file://$SRC BRIGADA_DIR=$clone
  pipe_install "$T0/bin"
  assert_eq 0 "$RC" "$OUT"
  # the human edited a file of the clone; the source changed the same file
  echo "# local" >>"$clone/bin/brg-global"
  echo "# upstream" >>"$SRC/bin/brg-global"
  git -C "$SRC" $GITC commit -qam two || fail "commit two"
  pipe_install "$T0/bin"
  assert_eq 1 "$RC" "pull --ff-only must fail:
$OUT"
  assert_contains "$OUT" "обнови вручную: git -C $clone pull"
  assert_eq "# local" "$(tail -n 1 "$clone/bin/brg-global")" "the local edit is intact"
  # a wrong repository address: an error, no question on the tty
  rm -rf "$clone"
  export BRIGADA_REPO=file://$T0/nonexistent
  pipe_install "$T0/bin"
  assert_eq 1 "$RC"
  assert_contains "$OUT" "не удалось клонировать"
  assert_file_not_exists "$clone"
}

test_install_relative_dir_becomes_absolute() {
  inst_need || return 0
  mk_src
  export BRIGADA_REPO=file://$SRC BRIGADA_DIR=rel/clone
  PIPE_CWD=$T0 pipe_install bin
  assert_eq 0 "$RC" "$OUT"
  assert_file_exists "$T0/rel/clone/.git"
  assert_contains "$(cat "$T0/bin/brg")" "BRIGADA_HOME=\"$T0/rel/clone\""
  assert_contains "$OUT" "$T0/bin/brg"
}

# From a clone — as before; a path with # & space and Cyrillic works, one with $ " ` \ is refused
test_install_from_clone_paths() {
  local d tgt out v n
  inst_need || return 0
  mk_src
  tgt=$T0/bin
  out=$(bash "$SRC/install.sh" "$tgt" 2>&1) || fail "install from a clone:
$out"
  assert_contains "$out" "── установлено: $tgt/brg → $SRC"
  assert_contains "$out" "добавь в PATH: export PATH=\"$tgt:\$PATH\""
  assert_eq "$(sed "s#@BRIGADA_HOME@#$SRC#" "$ROOT/bin/brg-global")" "$(cat "$tgt/brg")" "the same file the sed gave"
  assert_contains "$(ls -l "$tgt/brg")" "-rwxr-xr-x"
  out=$(PATH="$tgt:$PATH" bash "$SRC/install.sh" "$tgt" 2>&1)
  assert_contains "$out" "$tgt уже в PATH"
  # a path that sed would break
  d="$T0/a#b&c д"
  mkdir "$d"
  cp -R "$SRC/." "$d/"
  out=$(bash "$d/install.sh" "$T0/bin2" 2>&1) || fail "install from $d:
$out"
  assert_contains "$(cat "$T0/bin2/brg")" "BRIGADA_HOME=\"$d\""
  v=$(cd "$T0" && "$T0/bin2/brg" --version) || fail "brg --version from $d"
  assert_contains "$v" "brg "
  # characters that would be expanded by the shell inside the quotes
  for n in 'dollar$x' 'quote"q' 'back`tick' 'back\slash'; do
    d="$T0/$n"
    mkdir "$d"
    cp -R "$SRC/." "$d/"
    out=$(bash "$d/install.sh" "$T0/bin3" 2>&1)
    [ $? != 0 ] || fail "path [$n] was accepted"
    assert_contains "$out" "ломает команду brg"
    assert_file_not_exists "$T0/bin3/brg"
  done
  # relative target, run from the clone
  (cd "$SRC" && bash install.sh ../reltarget >/dev/null) || fail "relative target"
  assert_file_exists "$SRC/../reltarget/brg"
  assert_contains "$(cat "$SRC/../reltarget/brg")" "BRIGADA_HOME=\"$SRC\""
}
