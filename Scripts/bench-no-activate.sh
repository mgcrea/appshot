#!/usr/bin/env bash
# Prove the --no-activate guard fails when it should, against the fixture app.
#
# Three captures, each under --no-activate:
#
#   instant              well-behaved — must pass
#   raise-regardless     orderFrontRegardless() ungated — must fail as raised_above_front_app
#   activate-regardless  activate(ignoringOtherApps:) ungated — must fail as took_foreground
#
# The two controls put the fixture's window over whatever you are using for about a
# second each. That is the behaviour under test, so it cannot be avoided; the run stops
# at the first shot of each, so it happens once per control.
#
# The failure is matched on the message's first line, which each error case owns alone;
# AppShotError.slug maps the case to the slug, and ForegroundGuardTests pins the pair.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/.build/fixture/AppShotFixture.app"
APPSHOT="${APPSHOT:-$ROOT/.build/release/appshot}"
OUT="$ROOT/.build/fixture/no-activate"

failures=0

# control <stage> <slug or "pass"> <phrase the failure must contain>
control() {
    local stage="$1" want="$2" phrase="${3:-}"
    local log status
    log="$("$APPSHOT" capture --app "$APP" --out "$OUT/$stage" --screens "$stage" \
        --appearances dark --no-activate 2>&1)"
    status=$?

    if [ "$want" = "pass" ]; then
        if [ "$status" -eq 0 ]; then
            echo "  ✓ $stage passed"
        else
            echo "  ✗ $stage should have passed (exit $status):"
            echo "$log" | sed 's/^/      /'
            failures=$((failures + 1))
        fi
        return
    fi

    if [ "$status" -ne 0 ] && printf '%s' "$log" | grep -qF "$phrase"; then
        echo "  ✓ $stage failed as $want"
        printf '%s\n' "$log" | grep -F "$phrase" | sed 's/^/      /'
    else
        echo "  ✗ $stage should have failed as $want (exit $status):"
        echo "$log" | sed 's/^/      /'
        failures=$((failures + 1))
    fi
}

echo "Proving the --no-activate guard against the fixture:"
control instant pass
control raise-regardless raised_above_front_app "was ordered above"
control activate-regardless took_foreground "made itself frontmost"

if [ "$failures" -ne 0 ]; then
    echo
    echo "$failures of 3 controls got the wrong verdict — the guard is not trustworthy"
    exit 1
fi
echo
echo "✅ the guard reaches the right verdict on all 3 controls"
