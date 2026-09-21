#!/bin/sh
# Runs against live Reminders and Calendar data — that is where the gotchas live.
set -e
cd "$(dirname "$0")/.."
PAS=bin/pas

expect_fail() {
    if out=$("$@" 2>/dev/null); then
        echo "expected failure: $*" >&2
        exit 1
    fi
    [ -z "$out" ] || { echo "stdout not empty on failure: $*" >&2; exit 1; }
}

$PAS tasks | jq -e 'type == "array" and length > 0 and length < 512
    and (.[0].id | type == "string")
    and (.[0] | has("notes") and has("due") and has("priority"))' > /dev/null

START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
END=$(date -u -v+7d +%Y-%m-%dT%H:%M:%SZ)
$PAS events "$START" "$END" | jq -e 'type == "array"
    and all(.[]; (.calendarId | type == "string") and (.start | type == "string"))' > /dev/null

expect_fail $PAS tasks --list __no_such_list__
expect_fail $PAS events not-a-date "$END"
expect_fail $PAS

# The guards. These only ever exercise refusals, so they are safe to run unattended:
# a passing test here means nothing was written.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

WEEK=$($PAS events "$START" "$END")
CLASS_CAL=$(echo "$WEEK" | jq -r '[.[] | select(.calendar == "Class")][0].calendarId')
UNMARKED=$(echo "$WEEK" | jq -r '[.[] | select(.calendar == "Time Blocking")
    | select((.notes // "") | contains("pas-task:") | not)][0].id')

BLOCK='{taskId:"smoke",title:"pas smoke test, should never exist",
    start:"2030-01-01T18:00:00Z",end:"2030-01-01T19:00:00Z"}'

# Guard 1: a plan may name its calendar, but only the right one.
jq -n --arg c "$CLASS_CAL" "{calendarId:\$c,create:[$BLOCK]}" > "$TMP/wrong-calendar.json"
expect_fail $PAS apply "$TMP/wrong-calendar.json"

if [ "$UNMARKED" != "null" ] && [ -n "$UNMARKED" ]; then
    # Guard 2: an event without a pas-task: marker was not ours to delete.
    jq -n --arg i "$UNMARKED" '{delete:[$i]}' > "$TMP/unmarked.json"
    expect_fail $PAS apply "$TMP/unmarked.json"

    # A refused plan writes nothing, including the create that was fine on its own.
    jq -n --arg i "$UNMARKED" "{delete:[\$i],create:[$BLOCK]}" > "$TMP/mixed.json"
    expect_fail $PAS apply "$TMP/mixed.json"
    # Recurring events from today's calendars reach 2030, so check for the block
    # by title rather than asserting the window is empty.
    $PAS events 2030-01-01T00:00:00Z 2030-01-02T00:00:00Z \
        | jq -e '[.[] | select(.title | startswith("pas smoke test"))] | length == 0' > /dev/null
else
    echo "note: no unmarked Time Blocking event in the window, skipped the marker guard" >&2
fi

echo ok
