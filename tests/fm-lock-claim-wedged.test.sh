#!/usr/bin/env bash
# tests/fm-lock-claim-wedged.test.sh - bin/fm-lock.sh refuses, naming the
# holder, when a live process keeps the session-lock claim (state/.lock.acquire)
# past FM_LOCK_CLAIM_WAIT, and never steals it from that live holder.
# shellcheck disable=SC2016 # single quotes are deliberate: positional args expand in the child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lock-claim-wedged)
FAKEBIN=$(fm_fakebin "$TMP_ROOT/harness-bin")
ln -s /bin/bash "$FAKEBIN/claude"

test_wedged_claim_refuses_without_steal() {
  local state="$TMP_ROOT/state" holder out rc start elapsed
  mkdir -p "$state"
  FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$ROOT" \
    bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$2/.lock.acquire" || exit 1; : > "$2/held"; exec sleep 60' \
    _ "$ROOT" "$state" &
  holder=$!
  for _ in $(seq 1 100); do [ -e "$state/held" ] && break; sleep 0.1; done
  [ -e "$state/held" ] || fail "holder did not take the claim lock"
  [ "$(cat "$state/.lock.acquire/pid")" = "$holder" ] || fail "claim lock pid is not the holder"

  start=$SECONDS
  out=$(env -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID FM_STATE_OVERRIDE="$state" FM_LOCK_CLAIM_WAIT=2 \
    "$FAKEBIN/claude" -c 'bash "$1/bin/fm-lock.sh"' _ "$ROOT" 2>&1) && rc=0 || rc=$?
  elapsed=$((SECONDS - start))

  [ "$rc" -eq 1 ] || fail "wedged claim: expected exit 1, got $rc ($out)"
  [ "$elapsed" -lt 20 ] || fail "wedged claim: refusal took ${elapsed}s"
  case "$out" in *"still held after 2s by pid $holder"*) ;; *) fail "refusal does not name holder $holder: $out" ;; esac
  kill -0 "$holder" 2>/dev/null || fail "holder was killed"
  [ "$(cat "$state/.lock.acquire/pid")" = "$holder" ] || fail "claim lock was stolen from the live holder"
  [ ! -e "$state/.lock" ] || fail "session lock was written despite the refusal"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  pass "wedged claim lock: refuses within the bound, names the holder, leaves it intact"
}

test_wedged_claim_refuses_without_steal
