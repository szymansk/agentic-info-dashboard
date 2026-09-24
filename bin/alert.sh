#!/usr/bin/env bash
#
# alert.sh — einziger Alarm-Versandweg des ai-news-dashboards (Spec 5.4).
#
#   alert.sh <ART> <Text…>         Alarm auslösen (ART z.B. AUTH, STALE, GIVEUP)
#   alert.sh unit-failed <präfix>  von systemd OnFailure; liest last-failure.<kurz>
#   alert.sh --resend              pending-Alarme nachsenden (Watchdog, alle 30 min)
#   alert.sh --test                Testnachricht
#   Optionen: --force (Drosselung aus), --dry-run (nichts senden)
#
# Reihenfolge: Journal → Statusdateien → Kanäle (CallMeBot, ntfy). Der Drossel-
# Stempel eines Kanals wird nur bei dessen Erfolg gesetzt; sonst pending.
# Exit: 0 zugestellt/gedrosselt · 1 pending · 64 Usage
#
set -uo pipefail
LOG_TAG=alert
# shellcheck source=bin/lib-daily.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-daily.sh"

ALERT_REPEAT_SEC="${ALERT_REPEAT_SEC:-43200}"   # 12 h pro Vorfall und Kanal
MAX_RESEND="${MAX_RESEND:-6}"
CURL="${ALERT_CURL:-curl}"

FORCE=0; DRY=0; args=()
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    --dry-run) DRY=1 ;;
    *) args+=("$a") ;;
  esac
done
set -- "${args[@]+"${args[@]}"}"

if ! load_env "$ALERT_ENV"; then
  warn "alert.env fehlt oder ungültig ($ALERT_ENV) — nur Journal + Statusdateien"
fi

icon() {
  case "$1" in
    AUTH|TOKEN*|GIVEUP|API|REPO|DIRTY) echo "⛔" ;;
    HEARTBEAT|TEST) echo "✅" ;;
    *) echo "⚠" ;;
  esac
}
incident_hash() { printf '%s|%s' "$1" "${2:0:80}" | sha256sum | cut -c1-12; }

send_callmebot() {  # <text> → 0 queued · 1 Fehler · 2 nicht konfiguriert
  [ -n "${CALLMEBOT_PHONE:-}" ] && [ -n "${CALLMEBOT_APIKEY:-}" ] || return 2
  local body
  body="$("$CURL" -fsS -m 20 -G "https://api.callmebot.com/whatsapp.php" \
            --data-urlencode "phone=$CALLMEBOT_PHONE" \
            --data-urlencode "apikey=$CALLMEBOT_APIKEY" \
            --data-urlencode "text=$1" 2>/dev/null)" || return 1
  grep -qi "queued" <<<"$body"
}
send_ntfy() {  # <text> → 0 ok · 1 Fehler · 2 nicht konfiguriert
  [ -n "${NTFY_URL:-}" ] || [ -n "${NTFY_TOPIC:-}" ] || return 2
  "$CURL" -fsS -m 20 -H "Title: ai-news-dashboard" -H "Priority: high" \
    -d "$1" "${NTFY_URL:-https://ntfy.sh/${NTFY_TOPIC:-}}" >/dev/null 2>&1
}

# deliver <hash> <text> → 0 wenn mindestens ein Kanal zugestellt/gedrosselt hat
#   ODER kein Kanal konfiguriert ist (dann bleibt es bei Journal + Statusdateien,
#   siehe Test 9 / Spec 5.4 — kein pending, wenn es gar keinen Kanal zum Senden gibt).
deliver() {
  local hash="$1" text="$2" ch stamp rc any=1 configured=0
  for ch in callmebot ntfy; do
    stamp="$STATE_DIR/sent.$ch.$hash"
    if [ "$FORCE" != 1 ] && [ -f "$stamp" ] \
       && [ $(( $(date +%s) - $(stat -c %Y "$stamp") )) -lt "$ALERT_REPEAT_SEC" ]; then
      any=0; configured=1; continue
    fi
    if [ "$DRY" = 1 ]; then log "[dry-run] würde via $ch senden: $text"; any=0; continue; fi
    "send_$ch" "$text"; rc=$?
    case $rc in
      0) touch "$stamp"; any=0; configured=1; log "zugestellt via $ch" ;;
      2) ;;
      *) configured=1; warn "$ch fehlgeschlagen (rc=$rc)" ;;
    esac
  done
  [ "$configured" = 0 ] && return 0
  return $any
}

raise() {  # <ART> <Text>
  local kind="$1" text="$2" hash msg
  hash="$(incident_hash "$kind" "$text")"
  msg="$(printf '%s ai-news [%s] %s' "$(icon "$kind")" "$kind" "$text")"
  logger -p user.err -t ai-news-alert "[$kind] $text" 2>/dev/null || true
  mkdir -p "$STATE_DIR"
  printf '%s\t%s\t%s\n' "$(date -Is)" "$kind" "$text" >> "$STATE_DIR/alerts.log"
  printf '%s\n%s\n%s\n' "$kind" "$(date -Is)" "$text" > "$STATE_DIR/last-alert"
  if deliver "$hash" "$msg"; then
    rm -f "$STATE_DIR/pending/$hash" "$STATE_DIR/pending/$hash.tries"
    return 0
  fi
  [ "$DRY" = 1 ] && return 0
  mkdir -p "$STATE_DIR/pending"
  [ -f "$STATE_DIR/pending/$hash.tries" ] || echo 0 > "$STATE_DIR/pending/$hash.tries"
  printf '%s\n' "$msg" > "$STATE_DIR/pending/$hash"
  warn "nicht zugestellt — pending ($hash)"
  return 1
}

resend() {
  local f hash tries n
  [ -d "$STATE_DIR/pending" ] || return 0
  for f in "$STATE_DIR"/pending/*; do
    [ -f "$f" ] || continue
    [[ "$f" == *.tries ]] && continue
    hash="$(basename "$f")"
    tries="$(cat "$f.tries" 2>/dev/null || echo 0)"
    if [ "$tries" -ge "$MAX_RESEND" ]; then
      n="$(find "$STATE_DIR/pending" -type f ! -name '*.tries' | wc -l)"
      if FORCE=1 deliver "summary-$(date +%G-%V)" \
           "⚠ ai-news: $n Alarm(e) konnten mehrfach nicht zugestellt werden. Details: $STATE_DIR/alerts.log"; then
        rm -rf "$STATE_DIR/pending"
      fi
      return 0
    fi
    if FORCE=1 deliver "$hash" "$(cat "$f")"; then
      rm -f "$f" "$f.tries"
    else
      echo $((tries + 1)) > "$f.tries"
    fi
  done
}

unit_failed() {  # <unit-präfix>, z.B. ai-news-dashboard-daily
  local unit="$1" short="${1#ai-news-dashboard-}" f kind text
  f="$STATE_DIR/last-failure.$short"
  if [ -f "$f" ] && [ $(( $(date +%s) - $(stat -c %Y "$f") )) -lt 7200 ]; then
    kind="$(sed -n 1p "$f")"; text="$(sed -n '2,$p' "$f" | tr '\n' ' ')"
  else
    kind="FAILED"
    text="$(journalctl -u "$unit.service" -n 5 --no-pager -o cat 2>/dev/null | tail -3 | tr '\n' ' ')"
  fi
  raise "${kind:-FAILED}" "${short}: ${text:-ohne Grund in State/Journal} · journalctl -u $unit.service"
}

case "${1:-}" in
  --test)      raise TEST "Alarmkanal-Test $(date '+%d.%m. %H:%M'), Briefing vom $(snapshot_date "$PROJECT_DIR/dashboards/ai-news/index.html")" ;;
  --resend)    resend ;;
  unit-failed) [ -n "${2:-}" ] || { echo "usage: alert.sh unit-failed <unit-präfix>" >&2; exit 64; }
               unit_failed "$2" ;;
  "")          sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 64 ;;
  *)           [ -n "${2:-}" ] || { echo "usage: alert.sh <ART> <Text…>" >&2; exit 64; }
               raise "$1" "${*:2}" ;;
esac
