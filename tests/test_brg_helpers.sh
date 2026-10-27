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
