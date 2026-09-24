#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
. tests/lib-test.sh; test_sandbox
export ALERT_ENV="$CONF_DIR/alert.env"
printf 'CALLMEBOT_PHONE=491234\nCALLMEBOT_APIKEY=key\n' > "$ALERT_ENV"
stub logger 'exit 0'
# systemctl-Stub für unit_failed()s InvocationID-Abfrage (Fix B1)
stub systemctl 'case "$*" in *"-p InvocationID --value"*) echo inv-42 ;; *) exit 0 ;; esac'
# curl-Stub: protokolliert Aufrufe, antwortet je nach CURL_MODE
stub curl 'echo "$@" >> "$STUB_BIN/curl.log"
case "${CURL_MODE:-ok}" in
  ok)   echo "Message queued. You will receive it in a few seconds." ;;
  down) exit 7 ;;
  soft) echo "Error: APIKEY invalid" ;;
esac'
export ALERT_CURL="$STUB_BIN/curl"

# 1. Zustellung ok → Stempel, kein pending, exit 0
assert_rc 0 "alert ok" -- bin/alert.sh TEST "hallo welt"
assert_eq "1" "$(ls "$STATE_DIR"/sent.callmebot.* 2>/dev/null | wc -l)" "Stempel callmebot gesetzt"
assert_eq "0" "$(ls "$STATE_DIR/pending" 2>/dev/null | wc -l)" "kein pending"
assert_contains "text=" "$(cat "$STUB_BIN/curl.log")" "curl mit text"
assert_contains "TEST" "$(sed -n 1p "$STATE_DIR/last-alert")" "last-alert ART"

# 2. gleicher Vorfall erneut → gedrosselt, kein zweiter curl
: > "$STUB_BIN/curl.log"
assert_rc 0 "gedrosselt" -- bin/alert.sh TEST "hallo welt"
assert_eq "" "$(cat "$STUB_BIN/curl.log")" "kein curl bei Drosselung"

# 3. --force → sendet trotzdem
bin/alert.sh --force TEST "hallo welt" >/dev/null 2>&1
assert_contains "text=" "$(cat "$STUB_BIN/curl.log")" "--force sendet"

# 4. curl down → pending, exit 1, kein Stempel für neuen Vorfall
CURL_MODE=down bin/alert.sh STALE "briefing alt" >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "down → exit 1"
assert_eq "1" "$(ls "$STATE_DIR/pending" | grep -vc tries)" "pending angelegt"
assert_eq "0" "$(ls "$STATE_DIR"/sent.callmebot.* | grep -c "$(ls "$STATE_DIR/pending" | grep -v tries)")" "kein Stempel bei down"

# 5. soft-Fehler (200, aber nicht queued) → pending
CURL_MODE=soft bin/alert.sh AUTH "token weg" >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "soft → exit 1"

# 6. --resend mit curl ok → pending geleert
: > "$STUB_BIN/curl.log"
assert_rc 0 "resend" -- bin/alert.sh --resend
assert_eq "0" "$(ls "$STATE_DIR/pending" | grep -vc tries)" "pending nach resend leer"
assert_eq "2" "$(grep -c "text=" "$STUB_BIN/curl.log")" "zwei Nachsendungen"

# 7. --resend: nach 6 Versuchen Sammelnachricht + Abbruch
CURL_MODE=down bin/alert.sh YOUTUBE "yt alt" >/dev/null 2>&1
h="$(ls "$STATE_DIR/pending" | grep -v tries)"; echo 6 > "$STATE_DIR/pending/$h.tries"
: > "$STUB_BIN/curl.log"; bin/alert.sh --resend >/dev/null 2>&1
assert_contains "mehrfach nicht zugestellt" "$(cat "$STUB_BIN/curl.log")" "Sammelnachricht"
assert_eq "0" "$(ls "$STATE_DIR/pending" 2>/dev/null | wc -l)" "pending geräumt"

# 8. unit-failed liest last-failure.<kurzname>
printf 'GIVEUP\ndritter Fehlschlag: RUN 529\n' > "$STATE_DIR/last-failure.daily"
: > "$STUB_BIN/curl.log"; bin/alert.sh unit-failed ai-news-dashboard-daily >/dev/null 2>&1
assert_contains "GIVEUP" "$(cat "$STUB_BIN/curl.log")" "unit-failed nutzt ART aus last-failure"
assert_contains "529" "$(cat "$STUB_BIN/curl.log")" "unit-failed nutzt Text"
assert_eq "inv-42" "$(cat "$STATE_DIR/wd.failed-invocation" 2>/dev/null)" "InvocationID gestempelt (B1)"
assert_eq "GIVEUP" "$(sed -n 1p "$STATE_DIR/last-unit-alert" 2>/dev/null)" "last-unit-alert ART == last-alert ART (B1)"

# 9. fehlende alert.env → nur Journal, exit 0, kein curl
rm "$ALERT_ENV"; : > "$STUB_BIN/curl.log"
assert_rc 0 "ohne env" -- bin/alert.sh TEST "x"
assert_eq "" "$(cat "$STUB_BIN/curl.log")" "kein curl ohne env"

# 10. --dry-run sendet nicht
printf 'CALLMEBOT_PHONE=491234\nCALLMEBOT_APIKEY=key\n' > "$ALERT_ENV"
: > "$STUB_BIN/curl.log"; bin/alert.sh --dry-run TEST "dry" >/dev/null 2>&1
assert_eq "" "$(cat "$STUB_BIN/curl.log")" "dry-run ohne curl"
assert_rc 64 "usage" -- bin/alert.sh
test_summary
