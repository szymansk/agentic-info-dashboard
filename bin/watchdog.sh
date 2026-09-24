#!/usr/bin/env bash
#
# watchdog.sh — Prüfungen alle 30 min, nur Alarm, keine Reparatur (Spec 5.5).
#   --dry-run   alle Werte zeigen, nichts senden, keine Stempel; Exit 1 wenn ein Alarm anstünde
# Alarm-Arten: TOKEN, TOKEN_LIVE, STALE, PUBLIC_STALE, YOUTUBE, FAILED, GH_AUTH, HEARTBEAT
#
set -uo pipefail
LOG_TAG=watchdog
# shellcheck source=bin/lib-daily.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-daily.sh"
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALERT="$BIN/alert.sh"
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
load_env "$DAILY_ENV" || true
load_env "$ALERT_ENV" || true

TOKEN_WARN_DAYS="${TOKEN_WARN_DAYS:-14}"
STALE_HOUR="${STALE_HOUR:-14}"
YOUTUBE_MAX_H="${YOUTUBE_MAX_H:-30}"
PUBLIC_GRACE_MIN="${PUBLIC_GRACE_MIN:-60}"
UNIT=ai-news-dashboard-daily.service

NOW="$(date +%s)"; T="$(today)"
HOUR="${WD_NOW_HOUR:-$(date +%-H)}"; DOW="${WD_NOW_DOW:-$(date +%u)}"; WEEK="${WD_NOW_WEEK:-$(date +%G-%V)}"
WOULD=0

raise() {  # <ART> <Text> [--force]
  WOULD=1
  if [ "$DRY" = 1 ]; then log "[dry-run] ALARM [$1] $2"; return 0; fi
  "$ALERT" ${3:-} "$1" "$2" >/dev/null 2>&1 || true
}
once_per() {  # <stempel> <schlüssel> → 0 wenn für diesen Schlüssel noch nicht passiert
  [ "$(state_read "wd.$1")" = "$2" ] && return 1
  [ "$DRY" = 1 ] || state_write "wd.$1" "$2"
  return 0
}
unit_alert_recent() {  # <sekunden> → 0 wenn last-unit-alert (echter OnFailure-Alarm, von
  # alert.sh unit-failed geschrieben) jünger ist. Kein Ausschluss von ARTen mehr nötig
  # (Fix B1): last-unit-alert enthält nie einen Watchdog-eigenen Alarm.
  [ -f "$STATE_DIR/last-unit-alert" ] || return 1
  [ $(( NOW - $(stat -c %Y "$STATE_DIR/last-unit-alert") )) -lt "$1" ] || return 1
  return 0
}

# 0. pending nachsenden
[ "$DRY" = 1 ] || "$ALERT" --resend >/dev/null 2>&1 || true

# 1. Token-Restlaufzeit
TOKEN_DAYS=""
if [ -n "${TOKEN_CREATED:-}" ]; then
  TOKEN_DAYS=$(( 365 - $(days_between "$TOKEN_CREATED" "$T") ))
  log "Token: noch $TOKEN_DAYS Tage (erstellt $TOKEN_CREATED)"
  if [ "$TOKEN_DAYS" -le "$TOKEN_WARN_DAYS" ] && once_per token-warn "$T"; then
    raise TOKEN "Setup-Token läuft in $TOKEN_DAYS Tagen ab. Fix: 'claude setup-token' im Browser, dann bin/set-token.sh"
  fi
elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  warn "TOKEN_CREATED fehlt in daily.env — Ablaufwarnung unmöglich"
  once_per token-warn "$T" && raise TOKEN "TOKEN_CREATED fehlt in daily.env — bin/set-token.sh setzt es"
fi

# 2. Unit-Zustand
eval "$(systemctl show "$UNIT" -p ActiveState -p SubState -p Result -p InvocationID 2>/dev/null | sed 's/^/U_/')"
U_ActiveState="${U_ActiveState:-unknown}"; U_InvocationID="${U_InvocationID:-}"
RUNNING=0; case "$U_ActiveState" in active|activating) RUNNING=1 ;; esac
log "daily.service: $U_ActiveState/${U_SubState:-?} (Result=${U_Result:-?})"

# 3. Briefing lokal
CUR="$(snapshot_date "$PROJECT_DIR/dashboards/ai-news/index.html")"
AGE=999; [ -n "$CUR" ] && AGE="$(days_between "$CUR" "$T")"
LAST_RUN="$(python3 - "$STATE_DIR/last-run.json" 2>/dev/null <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(f"{d.get('finished','?')} exit {d.get('exit','?')} {d.get('kind','')}: {str(d.get('text',''))[:80]}")
except Exception:
    print("kein last-run.json")
PY
)"
log "Briefing vom ${CUR:-?} ($AGE Tage) · letzter Lauf: $LAST_RUN"
if [ "$RUNNING" = 1 ]; then
  log "Lauf aktiv — STALE-Prüfung ausgesetzt"
elif unit_alert_recent 86400; then
  log "Unit-Alarm < 24 h — STALE-Prüfung ausgesetzt"
elif { [ "$AGE" -ge 1 ] && [ "$HOUR" -ge "$STALE_HOUR" ]; } || [ "$AGE" -ge 2 ]; then
  raise STALE "Briefing vom ${CUR:-?} ist $AGE Tage alt. Letzter Lauf: $LAST_RUN · journalctl -u $UNIT"
fi

# 4. Briefing öffentlich (Pages)
PUB="$(curl -fsS -m 15 -H 'Cache-Control: no-cache' "$PAGES_URL" 2>/dev/null | grep -oE 'data-snapshot-date="[0-9-]{10}"' | head -1 | grep -oE '[0-9-]{10}' || true)"
log "Pages zeigt ${PUB:-nichts}"
# Ein fehlgeschlagener curl (PUB leer) ist kein Beleg für ein veraltetes Pages —
# nur ein tatsächlich gelesenes, älteres Datum alarmiert (Fix B3).
if [ -n "$CUR" ] && [ -n "$PUB" ] && [[ "$PUB" < "$CUR" ]] && [ -f "$STATE_DIR/last-run.json" ] \
   && [ $(( NOW - $(stat -c %Y "$STATE_DIR/last-run.json") )) -gt $(( PUBLIC_GRACE_MIN * 60 )) ]; then
  raise PUBLIC_STALE "Pages zeigt $PUB, lokal $CUR. Pages-Build/Push prüfen: gh run list, git status -sb"
fi

# 5. YouTube
YT="$PROJECT_DIR/dashboards/youtube/data.json"
if [ -f "$YT" ]; then
  YT_H=$(( ( NOW - $(stat -c %Y "$YT") ) / 3600 )); log "youtube/data.json: ${YT_H} h alt"
  [ "$YT_H" -gt "$YOUTUBE_MAX_H" ] && raise YOUTUBE "youtube/data.json ist ${YT_H} h alt. journalctl -u ai-news-dashboard-youtube-fetch"
else
  raise YOUTUBE "youtube/data.json fehlt"
fi

# 6. Unit failed (Sicherheitsnetz, falls OnFailure nicht griff)
# Stempel erst NACH dem tatsächlichen Alarm setzen — sonst verstummt eine
# neue InvocationID für immer, wenn ein frischer Unit-Alarm sie gerade unterdrückt.
if [ "$U_ActiveState" = failed ] && [ -n "$U_InvocationID" ] \
   && [ "$(state_read wd.failed-invocation)" != "$U_InvocationID" ] && ! unit_alert_recent 43200; then
  raise FAILED "daily.service ist failed (Result=${U_Result:-?}). journalctl -u $UNIT -n 30"
  [ "$DRY" = 1 ] || state_write wd.failed-invocation "$U_InvocationID"
fi

# 7. GitHub-Auth
if ! gh auth status >/dev/null 2>&1; then
  once_per gh-auth "$T" && raise GH_AUTH "gh auth status schlägt fehl — Push würde scheitern. Fix: gh auth login"
fi

# 8. Sonntag: Live-Check + Lebenszeichen
# Stempel erst NACH dem tatsächlichen Check setzen (Erfolg wie Fehlschlag) —
# sonst blockiert ein nicht auffindbares Binary den nächsten Versuch eine
# ganze Woche lang, ohne dass je ein Alarm ging.
LIVE="nicht geprüft"
if [ "$DOW" = 7 ] && [ "$HOUR" -ge 9 ] && [ "$(state_read wd.token-live)" != "$WEEK" ]; then
  if [ "$DRY" = 1 ]; then
    LIVE="[dry-run] Live-Check übersprungen"
  elif CLAUDE_BIN="$(resolve_claude)"; then
    TMPD="$(mktemp -d)"
    if ( cd "$TMPD" && DISABLE_AUTOUPDATER=1 timeout 120 "$CLAUDE_BIN" -p 'Antworte nur mit OK' \
          --model "${CLAUDE_MODEL:-claude-opus-4-8}" --max-turns 1 --strict-mcp-config \
          --setting-sources project --output-format json </dev/null 2>/dev/null \
        | grep -q '"is_error": *false' ); then LIVE="ok"
    else LIVE="FEHLER"; raise TOKEN_LIVE "Wöchentlicher Live-Check mit dem Setup-Token schlug fehl. Token/Modell prüfen: bin/run-daily.sh --dry-run"; fi
    rm -rf "$TMPD"
    state_write wd.token-live "$WEEK"
  else
    LIVE="FEHLER"
    raise TOKEN_LIVE "claude-Binary nicht gefunden — Live-Check unmöglich"
    state_write wd.token-live "$WEEK"
  fi
fi
if [ "$DOW" = 7 ] && [ "$HOUR" -ge 9 ] && [ "${HEARTBEAT:-1}" = 1 ] && once_per heartbeat "$WEEK"; then
  WF="$(gh run list --workflow stale-check.yml --limit 1 --json conclusion,createdAt -q '.[0] | "\(.conclusion) \(.createdAt)"' 2>/dev/null || echo "unbekannt")"
  raise HEARTBEAT "lebt. Briefing $CUR, letzter Lauf: $LAST_RUN, Token noch ${TOKEN_DAYS:-?} Tage, Live-Check: $LIVE, GitHub-Wächter: $WF" --force
fi

[ "$DRY" = 1 ] && exit "$WOULD"
exit 0
