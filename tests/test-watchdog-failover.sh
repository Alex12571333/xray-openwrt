#!/bin/sh
# Run with: sh tests/test-watchdog-failover.sh
# SINGBOX_SETUP_UNDER_TEST may point at another revision for a negative test.
set -eu

TEST_REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_SETUP=${SINGBOX_SETUP_UNDER_TEST:-$TEST_REPO_ROOT/xray-setup.sh}
TEST_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sb-watchdog-test.XXXXXX")
trap 'rm -rf "$TEST_WORK_DIR"' 0
trap 'exit 1' 1 2 15

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

# The command dispatcher must never execute. Fail closed if its marker changes.
awk '
    /^# ─── Main/ { found = 1; exit }
    { print }
    END { if (!found) exit 1 }
' "$TEST_SETUP" > "$TEST_WORK_DIR/definitions.sh" \
    || fail "Cannot isolate script definitions before Main"
. "$TEST_WORK_DIR/definitions.sh"

SINGBOX_SERVERS_FILE="$TEST_WORK_DIR/servers"
SINGBOX_VLESS_FILE="$TEST_WORK_DIR/selected"
SINGBOX_SUB_FILE="$TEST_WORK_DIR/subscription"
SINGBOX_AUTO_FILE="$TEST_WORK_DIR/auto"
SINGBOX_FAILOVER_STATE="$TEST_WORK_DIR/failover-state"
printf '%s\n' \
    'vless://11111111-1111-1111-1111-111111111111@preferred.example:443' \
    'vless://22222222-2222-2222-2222-222222222222@backup.example:443' \
    > "$SINGBOX_SERVERS_FILE"
sed -n '1p' "$SINGBOX_SERVERS_FILE" > "$SINGBOX_VLESS_FILE"
printf '%s\n' 'https://example.invalid/subscription' > "$SINGBOX_SUB_FILE"
: > "$SINGBOX_AUTO_FILE"

TEST_HEALTHY=1
TEST_ACTIVE_TAG=server-2
TEST_REFRESH_COUNT=0
TEST_NOW=2000000

# Run only the subscription decision function. All network access, service
# operations, transaction recovery and clock reads are replaced locally.
health_check() { [ "$TEST_HEALTHY" -eq 1 ]; }
_clash_group_now() {
    [ "${1:-}" = auto ] || fail "Unexpected Clash group: ${1:-missing}"
    printf '%s' "$TEST_ACTIVE_TAG"
}
_state_transaction() {
    [ "$#" -eq 1 ] && [ "$1" = refresh_subscription_and_apply ] \
        || fail "Unexpected transaction"
    "$@"
}
refresh_subscription_and_apply() { TEST_REFRESH_COUNT=$((TEST_REFRESH_COUNT + 1)); }
date() {
    [ "$#" -eq 1 ] && [ "$1" = +%s ] || fail "Unexpected clock request"
    printf '%s\n' "$TEST_NOW"
}
logger() { :; }

# These guards make an accidental call outside the intended seam fail safely.
curl() { fail "Unexpected network access: curl"; }
wget() { fail "Unexpected network access: wget"; }
_is_running() { fail "Unexpected process inspection"; }
start_singbox() { fail "Unexpected service start"; }
_stop_owned_singbox_processes() { fail "Unexpected process stop"; }
setup_iptables() { fail "Unexpected firewall setup"; }
cleanup_iptables() { fail "Unexpected firewall cleanup"; }
_watchdog() { fail "Unexpected full watchdog invocation"; }
_watchdog_locked() { fail "Unexpected full watchdog invocation"; }

run_checks() {
    TEST_CHECKS_LEFT=$1
    while [ "$TEST_CHECKS_LEFT" -gt 0 ]; do
        _watchdog_subscription_refresh
        TEST_CHECKS_LEFT=$((TEST_CHECKS_LEFT - 1))
    done
}

assert_refreshes() {
    [ "$TEST_REFRESH_COUNT" -eq "$1" ] \
        || fail "$2: expected $1 refreshes, got $TEST_REFRESH_COUNT"
}

assert_state() {
    [ -f "$SINGBOX_FAILOVER_STATE" ] || fail "$3: missing state"
    read -r TEST_STATE_PREFERRED TEST_STATE_FAILURES TEST_STATE_LAST_REFRESH \
        < "$SINGBOX_FAILOVER_STATE"
    [ "$TEST_STATE_PREFERRED" = server-1 ] \
        || fail "$3: preferred server changed"
    [ "$TEST_STATE_FAILURES" -eq "$1" ] \
        || fail "$3: expected $1 failures, got $TEST_STATE_FAILURES"
    [ "$TEST_STATE_LAST_REFRESH" -eq "$2" ] \
        || fail "$3: cooldown timestamp changed unexpectedly"
}

run_checks 4
assert_refreshes 0 "Healthy backup"
assert_state 0 0 "Healthy backup"
pass "Healthy backup never triggers a subscription refresh"

TEST_HEALTHY=0
run_checks 2
assert_refreshes 0 "Two failed checks"
assert_state 2 0 "Two failed checks"
pass "Two failed checks do not trigger a refresh"

TEST_HEALTHY=1
run_checks 1
assert_state 0 0 "Recovery resets failures"
TEST_HEALTHY=0
run_checks 2
assert_refreshes 0 "Recovery resets failures"
assert_state 2 0 "Recovery resets failures"
pass "A healthy backup resets the consecutive failure count"

run_checks 1
assert_refreshes 1 "Three consecutive failed checks"
assert_state 0 "$TEST_NOW" "Three consecutive failed checks"
pass "Three consecutive failed checks trigger a refresh"

run_checks 3
assert_refreshes 1 "Refresh cooldown"
assert_state 3 "$TEST_NOW" "Refresh cooldown"
pass "Cooldown prevents repeated refreshes"

TEST_HEALTHY=1
run_checks 1
assert_refreshes 1 "Healthy backup preserves cooldown"
assert_state 0 "$TEST_NOW" "Healthy backup preserves cooldown"
pass "A healthy backup preserves the last refresh timestamp"

TEST_NOW=$((TEST_NOW + 1800))
TEST_HEALTHY=0
run_checks 3
assert_refreshes 2 "Failure after cooldown"
assert_state 0 "$TEST_NOW" "Failure after cooldown"
pass "A later real failure can trigger recovery after cooldown"

rm -f "$SINGBOX_SUB_FILE"
run_checks 1
assert_refreshes 2 "No subscription"
[ ! -f "$SINGBOX_FAILOVER_STATE" ] || fail "No subscription: stale state remains"
pass "Without a subscription there is no automatic download"

printf '%s\n' 'All 8 watchdog failover regression checks passed.'
