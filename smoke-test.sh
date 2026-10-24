#!/usr/bin/env bash
# Drives dispatch.sh through the lifecycle Amp uses: spawn, idempotent spawn,
# pause, repeated pause, resume with a fresh token, pause with a snapshot, spawn a
# second orb from that snapshot, and delete. Bootstrap gets a dummy token and an
# unreachable AMP_URL, so it retries forever; that's expected.
# Does not verify Amp connectivity. Test a real thread afterward.
#
#   ./smoke-test.sh
set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
ORBCTL_BIN="${ORBCTL_BIN:-orbctl}"

ID="amp-smoke-$(date +%s)"
ID2="$ID-b"
SNAP_ID="smoke-$(date +%s)"
export ORB_IMAGE="ignored"

# dispatch <orb id> <operation> [token] [snapshot id]
dispatch() {
	ORB_ID="$1" ORB_OPERATION="$2" ORB_TOKEN="${3:-}" ORB_SNAPSHOT_ID="${4:-}" \
		AMP_URL="https://example.invalid" "$DIR/dispatch.sh"
}

state() { "$ORBCTL_BIN" info "$1" -f json 2>/dev/null | jq -r '.record.state' || echo gone; }

service_status() {
	"$ORBCTL_BIN" run -m "$1" -u root systemctl is-active amp-bootstrap || true
}

step() { printf '\n### %s\n' "$*"; }

fail() { echo "FAIL: $*" >&2; exit 1; }

cleanup() {
	step "delete"
	dispatch "$ID" delete || true
	dispatch "$ID2" delete || true
	"$ORBCTL_BIN" delete -f "amp-snap-$SNAP_ID" 2>/dev/null || true
	for m in "$ID" "$ID2" "amp-snap-$SNAP_ID"; do
		[[ "$(state "$m")" == gone ]] || { echo "FAIL: $m still exists" >&2; exit 1; }
	done
}
trap cleanup EXIT

step "spawn"
time dispatch "$ID" spawn smoke-token
[[ "$(service_status "$ID")" == active ]] || fail "bootstrap not active"

step "idempotent spawn"
dispatch "$ID" spawn smoke-token

step "pause"
time dispatch "$ID" pause
[[ "$(state "$ID")" == stopped ]] || fail "$ID not stopped"

step "pause again"
dispatch "$ID" pause

step "spawn (resume with fresh token)"
time dispatch "$ID" spawn fresh-smoke-token
"$ORBCTL_BIN" run -m "$ID" -u root grep -q fresh-smoke-token /etc/amp-orb/env || fail "token not updated"
[[ "$(service_status "$ID")" == active ]] || fail "bootstrap not active"

step "pause with snapshot"
time dispatch "$ID" pause "" "$SNAP_ID"
[[ "$(state "amp-snap-$SNAP_ID")" == stopped ]] || fail "snapshot not saved"

step "pause with snapshot again (replaces it)"
dispatch "$ID" pause "" "$SNAP_ID"

step "spawn second orb from snapshot"
time dispatch "$ID2" spawn snap-token "$SNAP_ID"
"$ORBCTL_BIN" run -m "$ID2" -u root test -f /etc/amp-orb-provisioned-v1 || fail "not cloned from snapshot"
[[ "$(service_status "$ID2")" == active ]] || fail "bootstrap not active"

echo
echo "OK"
