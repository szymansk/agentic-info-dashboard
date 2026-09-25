#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
. tests/lib-test.sh; test_sandbox
BIN="$PWD/bin"
export DAILY_ENV="$CONF_DIR/daily.env" ALERT_ENV="$CONF_DIR/alert.env" ALERT_CURL="$STUB_BIN/curl"
D1="$(date -I)"; D0="$(date -I -d "$D1 - 1 day")"; D3="$(date -I -d "$D1 - 3 day")"
stub logger 'exit 0'
stub curl 'echo "$@" >> "$STUB_BIN/curl.log"
case "$*" in
  *callmebot*) echo "Message queued" ;;
  *) if [ "${PAGES_FAIL:-0}" = 1 ]; then exit 7; fi
     printf "<body data-snapshot-date=\"%s\">" "${PAGES_DATE:-$(date -I)}" ;;
esac'
stub systemctl 'printf "ActiveState=%s\nSubState=%s\nResult=%s\nInvocationID=%s\n" "${UNIT_ACTIVE:-inactive}" dead "${UNIT_RESULT:-success}" "${UNIT_INV:-aaa}"'
stub gh 'case "$1" in auth) exit "${GH_AUTH_RC:-0}";; run) echo "success 2026-09-24T16:17:00Z";; esac'
stub claude 'echo "$@" >> "$STUB_BIN/claude.log"; echo "{\"is_error\":${CLAUDE_LIVE_ERR:-false},\"result\":\"OK\"}"'
export CLAUDE_BIN="$STUB_BIN/claude"
stub timeout 'shift; exec "$@"'
export PROJECT_DIR="$T_ROOT/proj"; mkdir -p "$PROJECT_DIR/dashboards/ai-news" "$PROJECT_DIR/dashboards/youtube"

setup() {  # setup <briefing-datum> <token-created> [youtube-age-h]
  rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"; : > "$STUB_BIN/curl.log"; : > "$STUB_BIN/claude.log"
  printf '<body data-snapshot-date="%s" data-snapshot-mode="live">' "$1" > "$PROJECT_DIR/dashboards/ai-news/index.html"
  printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-x\nTOKEN_CREATED=%s\nCLAUDE_MODEL=m\n' "$2" > "$DAILY_ENV"
  printf 'CALLMEBOT_PHONE=1\nCALLMEBOT_APIKEY=k\nHEARTBEAT=1\n' > "$ALERT_ENV"
  echo '{}' > "$PROJECT_DIR/dashboards/youtube/data.json"; touch -d "-${3:-1} hours" "$PROJECT_DIR/dashboards/youtube/data.json"
  printf '{"date":"%s","finished":"%sT08:00:00+0200","exit":0,"kind":"OK"}' "$1" "$1" > "$STATE_DIR/last-run.json"
  touch -d "-3 hours" "$STATE_DIR/last-run.json"
}
kinds() { cut -f2 "$STATE_DIR/alerts.log" 2>/dev/null | sort -u | tr '\n' ' '; }
run() { local rc=0; out="$("$BIN/watchdog.sh" "$@" 2>&1)" || rc=$?; echo "$rc"; }
wd_stamp() { [ -f "$STATE_DIR/wd.$1" ] && cat "$STATE_DIR/wd.$1" || true; }

# 1. alles frisch → kein Alarm, dry-run 0
setup "$D1" "$D1"; export WD_NOW_HOUR=10 WD_NOW_DOW=2 WD_NOW_WEEK=2026-39
assert_eq "0" "$(run)" "gesund → 0"; assert_eq "" "$(kinds)" "keine Alarme"
assert_eq "0" "$(run --dry-run)" "dry-run gesund → 0"

# 2. gestern + 15 Uhr → STALE; 10 Uhr → nicht
setup "$D0" "$D1"; WD_NOW_HOUR=15 run >/dev/null; assert_contains "STALE" "$(kinds)" "STALE ab 14 Uhr"
assert_contains "exit 0" "$(cut -f3 "$STATE_DIR/alerts.log" | tail -1)" "STALE-Text enthält letzten Lauf (LAST_RUN)"
setup "$D0" "$D1"; WD_NOW_HOUR=10 run >/dev/null; assert_eq "" "$(kinds)" "vor 14 Uhr kein STALE"
setup "$D3" "$D1"; WD_NOW_HOUR=8 run >/dev/null; assert_contains "STALE" "$(kinds)" "3 Tage → STALE immer"
setup "$D3" "$D1"; assert_eq "1" "$(WD_NOW_HOUR=8 run --dry-run)" "dry-run mit Alarm → 1"

# 2b. last-run.json fehlt → LAST_RUN zeigt "kein last-run.json" (statt Python-Syntaxfehler still zu schlucken)
setup "$D1" "$D1"; rm -f "$STATE_DIR/last-run.json"; run --dry-run >/dev/null
assert_contains "kein last-run.json" "$out" "LAST_RUN ohne Datei"

# 3. STALE unterdrückt, wenn Lauf aktiv oder Unit-Alarm < 24 h
setup "$D3" "$D1"; UNIT_ACTIVE=activating WD_NOW_HOUR=15 run >/dev/null; assert_eq "" "$(kinds)" "kein STALE während Lauf"
setup "$D3" "$D1"; printf 'GIVEUP\n%s\nx\n' "$(date -Is)" > "$STATE_DIR/last-unit-alert"
WD_NOW_HOUR=15 run >/dev/null; assert_eq "" "$(kinds | grep -o STALE)" "kein STALE nach Unit-Alarm (last-unit-alert, B1)"

# 4. Token-Warnung ab 14 Tagen, einmal pro Tag
setup "$D1" "$(date -I -d "$D1 - 355 day")"; run >/dev/null; assert_contains "TOKEN" "$(kinds)" "TOKEN-Warnung"
n1=$(wc -l < "$STATE_DIR/alerts.log"); run >/dev/null; assert_eq "$n1" "$(wc -l < "$STATE_DIR/alerts.log")" "TOKEN nur einmal pro Tag"
setup "$D1" "$(date -I -d "$D1 - 300 day")"; run >/dev/null; assert_eq "" "$(kinds | grep -o TOKEN)" "kein TOKEN bei 65 Tagen Rest"

# 4b. TOKEN_CREATED fehlt trotz vorhandenem Token → TOKEN, einmal pro Tag
setup "$D1" "$D1"; printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-x\nCLAUDE_MODEL=m\n' > "$DAILY_ENV"
run >/dev/null; assert_contains "TOKEN" "$(kinds)" "TOKEN ohne TOKEN_CREATED"
n1=$(wc -l < "$STATE_DIR/alerts.log"); run >/dev/null; assert_eq "$n1" "$(wc -l < "$STATE_DIR/alerts.log")" "TOKEN ohne TOKEN_CREATED nur einmal pro Tag"

# 5. YouTube > 30 h
setup "$D1" "$D1" 40; run >/dev/null; assert_contains "YOUTUBE" "$(kinds)" "YOUTUBE alt"

# 6. Unit failed → FAILED einmal pro InvocationID
setup "$D1" "$D1"; UNIT_ACTIVE=failed UNIT_RESULT=exit-code UNIT_INV=inv1 run >/dev/null
assert_contains "FAILED" "$(kinds)" "FAILED"; n1=$(wc -l < "$STATE_DIR/alerts.log")
UNIT_ACTIVE=failed UNIT_RESULT=exit-code UNIT_INV=inv1 run >/dev/null; assert_eq "$n1" "$(wc -l < "$STATE_DIR/alerts.log")" "FAILED nicht doppelt"
UNIT_ACTIVE=failed UNIT_RESULT=exit-code UNIT_INV=inv2 run >/dev/null; assert_eq "$((n1+1))" "$(wc -l < "$STATE_DIR/alerts.log")" "neue InvocationID → erneut"

# 6b. Stempel erst NACH dem Alarm — ein frischer Unit-Alarm (auch anderer ART,
# z.B. AUTH statt FAILED) darf die InvocationID nicht für immer verbrennen.
# last-unit-alert statt last-alert (B1): das ist die Datei, die alert.sh
# unit-failed tatsächlich schreibt.
setup "$D1" "$D1"; printf 'AUTH\n%s\nx\n' "$(date -Is)" > "$STATE_DIR/last-unit-alert"
UNIT_ACTIVE=failed UNIT_RESULT=exit-code UNIT_INV=inv9 run >/dev/null
assert_eq "" "$(kinds)" "kein FAILED bei frischem Unit-Alarm (AUTH)"
assert_eq "" "$(wd_stamp failed-invocation)" "kein Stempel vor tatsächlichem Alarm"
touch -d "-13 hours" "$STATE_DIR/last-unit-alert"
UNIT_ACTIVE=failed UNIT_RESULT=exit-code UNIT_INV=inv9 run >/dev/null
assert_contains "FAILED" "$(kinds)" "FAILED nach Ablauf des Unit-Alarms"
assert_eq "inv9" "$(wd_stamp failed-invocation)" "Stempel erst nach dem Alarm gesetzt"

# 6c. wd.failed-invocation bereits == aktuelle InvocationID → kein FAILED, auch
# wenn kein last-unit-alert existiert (der Stempel selbst ist die Sperre, nicht
# nur das 12h-Zeitfenster — B1)
setup "$D1" "$D1"; echo inv7 > "$STATE_DIR/wd.failed-invocation"
UNIT_ACTIVE=failed UNIT_RESULT=exit-code UNIT_INV=inv7 run >/dev/null
assert_eq "" "$(kinds)" "kein FAILED bei bereits gestempelter InvocationID"

# 7. PUBLIC_STALE: Pages zeigt altes Datum, letzter Lauf > 60 min her
setup "$D1" "$D1"; PAGES_DATE="$D0" run >/dev/null; assert_contains "PUBLIC_STALE" "$(kinds)" "PUBLIC_STALE"
setup "$D1" "$D1"; touch "$STATE_DIR/last-run.json"; PAGES_DATE="$D0" run >/dev/null; assert_eq "" "$(kinds | grep -o PUBLIC)" "keine PUBLIC_STALE in der Gnadenfrist"
# 7b. Pages-curl schlägt fehl (kein Output) → kein PUBLIC_STALE (Fix B3: ein
# fehlgeschlagener curl ist kein Beleg für ein veraltetes Pages)
setup "$D1" "$D1"; PAGES_FAIL=1 run >/dev/null
assert_eq "" "$(kinds | grep -o PUBLIC_STALE)" "kein PUBLIC_STALE bei fehlgeschlagenem curl"

# 8. gh auth kaputt → GH_AUTH einmal pro Tag
setup "$D1" "$D1"; GH_AUTH_RC=1 run >/dev/null; assert_contains "GH_AUTH" "$(kinds)" "GH_AUTH"

# 9. Sonntag ab 09:00: Live-Check + Heartbeat einmal pro Woche; --resend wird aufgerufen
setup "$D1" "$D1"; WD_NOW_HOUR=10 WD_NOW_DOW=7 run >/dev/null
assert_contains "HEARTBEAT" "$(kinds)" "Heartbeat"; assert_contains "--max-turns" "$(cat "$STUB_BIN/claude.log")" "Live-Check lief"
n1=$(wc -l < "$STATE_DIR/alerts.log"); WD_NOW_HOUR=10 WD_NOW_DOW=7 run >/dev/null; assert_eq "$n1" "$(wc -l < "$STATE_DIR/alerts.log")" "Heartbeat nur einmal pro Woche"
setup "$D1" "$D1"; CLAUDE_LIVE_ERR=true WD_NOW_HOUR=10 WD_NOW_DOW=7 run >/dev/null; assert_contains "TOKEN_LIVE" "$(kinds)" "Live-Check-Fehler → TOKEN_LIVE"
setup "$D1" "$D1"; WD_NOW_HOUR=10 WD_NOW_DOW=7 run --dry-run >/dev/null; assert_eq "" "$(cat "$STUB_BIN/claude.log")" "dry-run ohne Live-Check"

# 9a. Sonntag, aber vor 09:00 (B2) → weder Live-Check noch Heartbeat, kein Stempel
setup "$D1" "$D1"; WD_NOW_HOUR=3 WD_NOW_DOW=7 run >/dev/null
assert_eq "" "$(kinds)" "kein Alarm Sonntag 03:00 Uhr"
assert_eq "" "$(cat "$STUB_BIN/claude.log")" "kein Live-Check Sonntag 03:00 Uhr"
assert_eq "" "$(wd_stamp heartbeat)" "kein Heartbeat-Stempel Sonntag 03:00 Uhr"
assert_eq "" "$(wd_stamp token-live)" "kein Live-Check-Stempel Sonntag 03:00 Uhr"

# 9b. claude-Binary nicht auffindbar → TOKEN_LIVE (Stempel erst nach dem Versuch, nicht davor)
setup "$D1" "$D1"; chmod -x "$STUB_BIN/claude"
OLD_HOME="$HOME"; export HOME="$T_ROOT/fakehome"; export CLAUDE_BIN=/nonexistent/claude
WD_NOW_HOUR=10 WD_NOW_DOW=7 run >/dev/null
export HOME="$OLD_HOME"; export CLAUDE_BIN="$STUB_BIN/claude"; chmod +x "$STUB_BIN/claude"
assert_contains "TOKEN_LIVE" "$(kinds)" "TOKEN_LIVE ohne claude-Binary"
assert_eq "2026-39" "$(wd_stamp token-live)" "Stempel nach dem Fehlschlag gesetzt"
test_summary
