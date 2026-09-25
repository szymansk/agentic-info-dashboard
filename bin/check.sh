#!/usr/bin/env bash
#
# Health-Check: zeigt den Zustand aller Services, Timer und Dashboards.
# Exit-Code != 0, wenn etwas Wichtiges nicht läuft.
#
set -uo pipefail

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PORT="${PORT:-8000}"
BASE="http://localhost:${PORT}"

errors=0

ok()   { printf "  \033[32m✓\033[0m %s\n" "$*"; }
warn() { printf "  \033[33m⚠\033[0m %s\n" "$*"; errors=$((errors+1)); }
err()  { printf "  \033[31m✗\033[0m %s\n" "$*"; errors=$((errors+1)); }
hdr()  { printf "\n\033[1m== %s ==\033[0m\n" "$*"; }

hdr "systemd units"
for unit in \
  ai-news-dashboard.service \
  ai-news-dashboard-youtube-fetch.timer \
  ai-news-dashboard-youtube-fetch.service \
  ai-news-dashboard-daily.timer \
  ai-news-dashboard-watchdog.timer \
; do
  state="$(systemctl is-active "$unit" 2>&1)"
  enabled="$(systemctl is-enabled "$unit" 2>&1)"
  case "$state" in
    active|activating) ok "$unit  ($state, $enabled)" ;;
    inactive)
      # oneshot/timer Services dürfen inactive sein, das ist ihr Normalzustand
      if [[ "$unit" == *.timer || "$unit" == *youtube-fetch.service ]]; then
        ok "$unit  ($state, $enabled — oneshot/timer, OK)"
      else
        err "$unit  ($state, $enabled)"
      fi
      ;;
    failed)
      err "$unit  ($state, $enabled)"
      ;;
    *) err "$unit  ($state, $enabled)" ;;
  esac
done

hdr "next timer fires"
systemctl list-timers ai-news-dashboard-* --no-pager 2>&1 | grep -v 'NEXT\|^$\|timers listed' | head -5 || warn "keine timer registriert"

hdr "HTTP routes"
for path in / /ai-news/ /whoiswho/ /sources/ /youtube/ /youtube/data.json /_shared/people.js; do
  resp=$(curl -s -o /dev/null -w "%{http_code} %{size_download}b" --max-time 3 "${BASE}${path}")
  code="${resp%% *}"
  if [ "$code" = "200" ]; then
    ok "${path} → ${resp}"
  else
    err "${path} → ${resp}"
  fi
done

hdr "data freshness"
youtube_json="$PROJECT_DIR/dashboards/youtube/data.json"
if [ -f "$youtube_json" ]; then
  age_sec=$(( $(date +%s) - $(stat -c %Y "$youtube_json") ))
  age_h=$(( age_sec / 3600 ))
  if [ "$age_h" -lt 30 ]; then
    ok "youtube/data.json  Alter: ${age_h}h"
  else
    warn "youtube/data.json  Alter: ${age_h}h (älter als 30h)"
  fi
else
  err "youtube/data.json fehlt"
fi

ai_news="$PROJECT_DIR/dashboards/ai-news/index.html"
if [ -f "$ai_news" ]; then
  snap_date=$(grep -oE 'data-snapshot-date="[0-9-]+"' "$ai_news" | head -1 | sed 's/.*"\(.*\)"/\1/')
  today=$(date -I)
  if [ "$snap_date" = "$today" ]; then
    ok "ai-news snapshot-date  $snap_date (heute)"
  else
    age_days=$(( ( $(date -d "$today" +%s) - $(date -d "$snap_date" +%s) ) / 86400 ))
    if [ "$age_days" -le 1 ]; then
      ok "ai-news snapshot-date  $snap_date (gestern — Tageslauf steht noch aus)"
    else
      warn "ai-news snapshot-date  $snap_date (${age_days} Tage alt, heute = $today)"
    fi
  fi
fi

hdr "daily run (claude -p oneshot)"
STATE_DIR="${STATE_DIR:-$HOME/.local/state/ai-news-dashboard}"
if [ -f "$STATE_DIR/last-run.json" ]; then
  python3 - "$STATE_DIR/last-run.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"  · letzter Lauf: {d.get('finished','?')} · Exit {d.get('exit','?')} ({d.get('kind','')}) · {d.get('duration_s','?')} s · {d.get('total_cost_usd') or '?'} USD · {d.get('num_turns') or '?'} Turns · CLI {d.get('claude_version','?')}")
print(f"  · {d.get('status') or d.get('text','')}")
PY
  [ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["exit"])' "$STATE_DIR/last-run.json")" = 0 ] \
    && ok "letzter Lauf erfolgreich" || err "letzter Lauf gescheitert — journalctl -u ai-news-dashboard-daily -n 40"
else
  warn "noch kein last-run.json (kein Oneshot-Lauf bisher)"
fi
d_state="$(systemctl show ai-news-dashboard-daily.service -p ActiveState -p SubState --value 2>/dev/null | tr '\n' '/')"
d_next="$(systemctl show ai-news-dashboard-daily.timer -p NextElapseUSecRealtime --value 2>/dev/null)"
case "$d_state" in
  activating/auto-restart/) warn "daily.service wartet auf Retry (auto-restart) · nächster Timer: ${d_next:-?}" ;;
  active/*|activating/start/) ok "daily.service läuft gerade" ;;
  failed/*) err "daily.service failed — Alarm sollte gekommen sein; journalctl -u ai-news-dashboard-daily -n 40" ;;
  *) ok "daily.service ${d_state:-unbekannt} · nächster Timer: ${d_next:-?}" ;;
esac
w_res="$(systemctl show ai-news-dashboard-watchdog.service -p Result -p ExecMainStatus --value 2>/dev/null | tr '\n' ' ')"
[ "${w_res% }" = "success 0" ] && ok "watchdog.service letzter Lauf ok" || warn "watchdog.service: ${w_res:-nie gelaufen} — journalctl -u ai-news-dashboard-watchdog -n 20"

# Preflight des Tageslaufs (Token, Tree, Repo) und Watchdog-Sicht — beides ohne Nebenwirkung
pre="$("$PROJECT_DIR/bin/run-daily.sh" --dry-run 2>&1 </dev/null)"; pre_rc=$?
printf '%s\n' "$pre" | sed 's/^  \[daily\] /    /'
case "$pre_rc" in 0) ok "Preflight ok" ;; *) err "Preflight scheitert (Exit $pre_rc) — siehe oben" ;; esac
wd="$("$PROJECT_DIR/bin/watchdog.sh" --dry-run 2>&1)"; wd_rc=$?
printf '%s\n' "$wd" | sed 's/^  \[watchdog\] /    /'
case "$wd_rc" in 0) ok "Watchdog: nichts zu melden" ;; *) warn "Watchdog würde alarmieren — siehe oben" ;; esac
if [ -f "$STATE_DIR/last-alert" ]; then
  err "letzter Alarm [$(sed -n 1p "$STATE_DIR/last-alert")] $(sed -n 2p "$STATE_DIR/last-alert"): $(sed -n 3p "$STATE_DIR/last-alert")"
fi
if [ -d "$STATE_DIR/pending" ] && [ -n "$(ls -A "$STATE_DIR/pending" 2>/dev/null)" ]; then
  warn "unzugestellte Alarme in $STATE_DIR/pending"
fi
if ! grep -qs '^HEALTHCHECKS_URL=.\+' "$HOME/.config/ai-news-dashboard/alert.env" 2>/dev/null; then
  warn "kein healthchecks.io konfiguriert — externer Wächter ist nur der GitHub-Workflow (gh run list --workflow stale-check.yml)"
fi

hdr "summary"
if [ "$errors" -eq 0 ]; then
  printf "  \033[32m✓ alles im grünen Bereich\033[0m\n"
  exit 0
else
  printf "  \033[31m✗ %d Probleme\033[0m — siehe oben\n" "$errors"
  exit 1
fi
