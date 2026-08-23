#!/usr/bin/env bash
# Delivers a real push to the sample app on a booted simulator and asserts the SDK handled it.
#
# `xcrun simctl push` injects the payload the way APNs would, without ever reaching Apple — so
# this needs no `.p8`, no paid membership and no device. It is the only automated path that runs
# `Platform/`'s notification-centre delegate and the NotificationService extension against a real
# notification rather than a constructed one.
set -euo pipefail

BUNDLE_ID="${BUNDLE_ID:-com.example.arselsample.staging}"
SAMPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../Examples/Sample" && pwd)"
PAYLOAD="${PAYLOAD:-$SAMPLE_DIR/Payloads/arsel-test.apns}"
CONSOLE="$(mktemp -t arsel-push-smoke)"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-45}"

cleanup() { [[ -n "${CONSOLE_PID:-}" ]] && kill "$CONSOLE_PID" 2>/dev/null || true; }
trap cleanup EXIT

DEVICE="$(xcrun simctl list devices booted -j | python3 -c '
import json,sys
for runtime in json.load(sys.stdin)["devices"].values():
    for device in runtime:
        print(device["udid"]); raise SystemExit
')"
[[ -n "$DEVICE" ]] || { echo "no booted simulator — run: xcrun simctl boot <udid>" >&2; exit 1; }
echo "device:  $DEVICE"
echo "bundle:  $BUNDLE_ID"

# The app must hold notification authorisation or the OS drops the push before the delegate runs,
# and the harness only requests it from a button tap. Granting it out-of-band writes the simulator's
# TCC store, which GitHub's hosted runners refuse ("Failed to set access: Operation not permitted").
# Exit 78 rather than 1 there: nothing was proven, but nothing is broken either, and the caller can
# tell the two apart. Locally, on a Mac you own, this succeeds and the test runs for real.
if ! xcrun simctl privacy "$DEVICE" grant notifications "$BUNDLE_ID"; then
    echo "SKIP — cannot grant notification authorisation on this host; the push would be dropped undelivered." >&2
    exit 78
fi

# --console streams the app's stdout, which is where the harness mirrors its SDK timeline.
xcrun simctl launch --console "$DEVICE" "$BUNDLE_ID" >"$CONSOLE" 2>&1 &
CONSOLE_PID=$!

# Wait for the app to actually be up before pushing; a push into a dead app proves nothing.
for _ in $(seq 1 30); do
    grep -q "\[harness\]" "$CONSOLE" && break
    sleep 1
done

xcrun simctl push "$DEVICE" "$BUNDLE_ID" "$PAYLOAD"

# The app is foregrounded, so the delegate takes the willPresent path and the SDK reports
# `displayed`. Poll rather than sleep a fixed amount.
for _ in $(seq 1 "$TIMEOUT_SECONDS"); do
    if grep -q "foreground push: mid=" "$CONSOLE"; then
        echo "PASS — SDK reported the displayed engagement:"
        grep "foreground push: mid=" "$CONSOLE"
        exit 0
    fi
    sleep 1
done

echo "FAIL — no engagement reported within ${TIMEOUT_SECONDS}s. Console output:" >&2
cat "$CONSOLE" >&2
exit 1
