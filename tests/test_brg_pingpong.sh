# Scripted ping-pong (tests/pingpong.sh), ≥ 200 exchanges with
# takeovers and killed waits. ~1 min. Skip with BRG_SKIP_PINGPONG=1.

TEST_TIMEOUT=${PINGPONG_TIMEOUT:-300}

test_pingpong_200() {
  local out
  if [ -n "${BRG_SKIP_PINGPONG:-}" ]; then
    echo "пропущено (BRG_SKIP_PINGPONG)"
    return 0
  fi
  out=$(bash "$TESTS_DIR/pingpong.sh" -n 200 2>&1)
  local rc=$?
  printf '%s\n' "$out"
  [ $rc -eq 0 ] || fail "pingpong failed"
  assert_contains "$out" "последовательность в tail: OK"
  assert_contains "$out" "паузы > 60 с: OK"
}
