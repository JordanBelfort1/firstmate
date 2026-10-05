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


# A holder that releases the claim after a brief hold: fm-lock.sh must wait it
# out and take the session lock instead of refusing.
test_brief_contention_acquires() {
  local state="$TMP_ROOT/state-brief" holder out rc
  mkdir -p "$state"
  FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$ROOT" \
    bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$2/.lock.acquire" || exit 1; : > "$2/held"; sleep 1; fm_lock_release "$2/.lock.acquire"' \
    _ "$ROOT" "$state" &
  holder=$!
  for _ in $(seq 1 100); do [ -e "$state/held" ] && break; sleep 0.1; done
  [ -e "$state/held" ] || fail "holder did not take the claim lock"

  out=$(env -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID FM_STATE_OVERRIDE="$state" FM_LOCK_CLAIM_WAIT=20 \
    "$FAKEBIN/claude" -c 'bash "$1/bin/fm-lock.sh"' _ "$ROOT" 2>&1) && rc=0 || rc=$?
  wait "$holder" 2>/dev/null
  [ "$rc" -eq 0 ] || fail "brief contention: expected exit 0, got $rc ($out)"
  [ -s "$state/.lock" ] || fail "brief contention: session lock was not written"
  pass "briefly contended claim lock: waits for release and acquires"
}

# When the bounded wait fails for a reason other than its deadline (here a
# broken timeout runner), fm-lock.sh still refuses within the bound and never
# falls back to an unbounded wait.
test_non_timeout_failure_refuses() {
  local state="$TMP_ROOT/state-broken" brokenbin="$TMP_ROOT/broken-bin" holder out rc start elapsed
  mkdir -p "$state" "$brokenbin"
  printf '#!/bin/sh\nexit 1\n' > "$brokenbin/timeout"
  chmod +x "$brokenbin/timeout"
  FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$ROOT" \
    bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$2/.lock.acquire" || exit 1; : > "$2/held"; exec sleep 60' \
    _ "$ROOT" "$state" &
  holder=$!
  for _ in $(seq 1 100); do [ -e "$state/held" ] && break; sleep 0.1; done
  [ -e "$state/held" ] || fail "holder did not take the claim lock"

  start=$SECONDS
  out=$(env -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID PATH="$brokenbin:$PATH" FM_STATE_OVERRIDE="$state" FM_LOCK_CLAIM_WAIT=5 \
    "$FAKEBIN/claude" -c 'bash "$1/bin/fm-lock.sh"' _ "$ROOT" 2>&1) && rc=0 || rc=$?
  elapsed=$((SECONDS - start))

  [ "$rc" -eq 1 ] || fail "non-timeout failure: expected exit 1, got $rc ($out)"
  [ "$elapsed" -lt 20 ] || fail "non-timeout failure: refusal took ${elapsed}s"
  case "$out" in *"cannot acquire session-lock claim"*) ;; *) fail "non-timeout failure: unexpected refusal: $out" ;; esac
  kill -0 "$holder" 2>/dev/null || fail "holder was killed"
  [ "$(cat "$state/.lock.acquire/pid")" = "$holder" ] || fail "claim lock was stolen from the live holder"
  [ ! -e "$state/.lock" ] || fail "session lock was written despite the refusal"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  pass "non-timeout claim failure: refuses within the bound without stealing"
}

test_wedged_claim_refuses_without_steal
test_brief_contention_acquires
test_non_timeout_failure_refuses
