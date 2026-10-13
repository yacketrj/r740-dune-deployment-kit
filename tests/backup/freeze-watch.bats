#!/usr/bin/env bats
# freeze-watch.bats -- tests for scripts/backup-freeze-watch.sh (keeps a guest's backup freeze short, #126).
# qm and curl are stubs; the "guest" is the file $T/frozen.
load helper

setup() {
  setup_env
  SCRIPT="$REPO_ROOT/scripts/backup-freeze-watch.sh"
  T="$BATS_TEST_TMPDIR"
  printf 'https://discord.com/api/webhooks/1/x\n' >"$T/hook"
  printf 'BK_DISCORD_WEBHOOK_FILE=%s\n' "$T/hook" >"$BK_CONFIG_DIR/backup.env"
  cat >"$T/bin/qm" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$T/qm.calls"
[ "\$1" = guest ] || exit 0
case "\$4" in
  fsfreeze-status)
    if [ -f "$T/silent" ]; then sleep 20; fi
    if [ -f "$T/frozen" ]; then echo frozen; else echo thawed; fi ;;
  fsfreeze-thaw) rm -f "$T/frozen"; echo 2 ;;
esac
EOF
  chmod +x "$T/bin/qm"
  stub curl 'cat >>"$BATS_TEST_TMPDIR/curl.stdin"; echo "$*" >>"$BATS_TEST_TMPDIR/curl.args"'
}
teardown() { pkill -KILL -fx "sleep 311" 2>/dev/null || true; pkill -KILL -fx "sleep 313" 2>/dev/null || true; }

thawed_calls() { grep -c 'fsfreeze-thaw' "$T/qm.calls" 2>/dev/null || true; }

@test "a short freeze is logged and does not alert or force a thaw" {
  ( sleep 1; touch "$T/frozen"; sleep 2; rm -f "$T/frozen" ) &
  sleep 311 & target=$!
  ( sleep 7; kill "$target" ) &
  run bash "$SCRIPT" --vmid 101 --target "$target" --max-s 20 --warn-s 10
  [ "$status" -eq 0 ]
  [[ "$output" == *"frozen for about"* ]]
  [ "$(thawed_calls)" = "0" ]
  [ ! -e "$T/curl.args" ]
}

@test "a freeze that outlasts --max-s is thawed by force and alerts" {
  touch "$T/frozen"
  sleep 311 & target=$!
  ( sleep 9; kill "$target" ) &
  run bash "$SCRIPT" --vmid 101 --target "$target" --max-s 2 --warn-s 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"forcing a thaw (frozen for more than 2s)"* ]]
  [ ! -e "$T/frozen" ]
  [ "$(thawed_calls)" -ge 1 ]
  grep -q "frozen for more than 2s" "$T/curl.args"
}

@test "a freeze longer than --warn-s but shorter than --max-s alerts once it ends, without forcing" {
  ( sleep 1; touch "$T/frozen"; sleep 4; rm -f "$T/frozen" ) &
  sleep 311 & target=$!
  ( sleep 9; kill "$target" ) &
  run bash "$SCRIPT" --vmid 101 --target "$target" --max-s 20 --warn-s 2
  [ "$status" -eq 0 ]
  [ "$(thawed_calls)" = "0" ]
  grep -q "frozen for about" "$T/curl.args"
}

@test "the job ending while the guest is frozen thaws it and alerts" {
  touch "$T/frozen"
  sleep 311 & target=$!
  ( sleep 3; kill "$target" ) &
  run bash "$SCRIPT" --vmid 101 --target "$target" --max-s 60 --warn-s 30
  [ "$status" -eq 0 ]
  [ ! -e "$T/frozen" ]
  grep -q "ended while the guest was still frozen" "$T/curl.args"
}

@test "an agent that stops answering gets one thaw attempt and an alert" {
  touch "$T/silent" "$T/frozen"
  sleep 311 & target=$!
  ( sleep 14; kill "$target" ) &
  run bash "$SCRIPT" --vmid 101 --target "$target" --max-s 3 --warn-s 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"has not answered for more than 3s"* ]]
  [ "$(thawed_calls)" -ge 1 ]
  grep -q "has not answered" "$T/curl.args"
  [ "$(grep -c 'has not answered' "$T/curl.args")" = "1" ]
}

@test "bad arguments are refused without touching the guest" {
  run bash "$SCRIPT" --vmid "101; reboot" --target 1
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --vmid 101 --target abc
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --vmid 101 --target 1 --max-s 0
  [ "$status" -eq 2 ]
  [ ! -e "$T/qm.calls" ]
}
