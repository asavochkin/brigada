# Small shared helpers of bin/brg, loaded with BRG_SOURCE_ONLY=1.

. "$TESTS_DIR/brg_lib.sh"

# dec_v: decimal with leading zeros, at most 9 digits, junk refused with VAR untouched
test_dec_v() {
  local out
  out=$(BRG_SOURCE_ONLY=1 bash -c '
    . "$1"
    for v in 0 7 08 010 0009 999999999 0999999999 1000000000 "" -1 +5 1.5 " 8" 8x 0x10; do
      r=keep
      if dec_v r "$v"; then printf "[%s]=%s\n" "$v" "$r"; else printf "[%s]!%s\n" "$v" "$r"; fi
    done' _ "$BRG_SRC")
  assert_eq "[0]=0
[7]=7
[08]=8
[010]=10
[0009]=9
[999999999]=999999999
[0999999999]!keep
[1000000000]!keep
[]!keep
[-1]!keep
[+5]!keep
[1.5]!keep
[ 8]!keep
[8x]!keep
[0x10]!keep" "$out"
}

# board_settled: a task closed an hour ago is settled even with a run record still
# "running" (the epoch has 10 digits — not dec_v); a fresh close with it is not
test_board_settled_epoch() {
  local a d out
  new_proj
  a=$(join_as claude)
  task_new_as "$a" "задача"
  brg task cancel --as human >/dev/null || fail "task cancel"
  d=$B/tasks/T001
  mkdir -p "$d/shared/runs"
  printf 'Id: R001\nTask: T001\nAgent: claude-1\nCommand: make\nMode: bg\nTimeout: 100\nStatus: running\nRequested: x\nRequested-Epoch: 1\n\n' >"$d/shared/runs/R001"
  out=$(BRG_SOURCE_ONLY=1 bash -c '
    . "$1"
    get_now
    board_settled "$2" && echo fresh-settled || echo fresh-live
    sed "s/^Closed-Epoch: .*/Closed-Epoch: $((NOW - 3600))/" "$2/task" >"$2/task.new" && mv "$2/task.new" "$2/task"
    board_settled "$2" && echo old-settled || echo old-live' _ "$BRG" "$d")
  assert_eq "fresh-live
old-settled" "$out"
}
