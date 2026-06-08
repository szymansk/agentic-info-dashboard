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
  ai-news-dashboard-daily-loop.service \
; do
  state="$(systemctl is-active "$unit" 2>&1)"
  enabled="$(systemctl is-enabled "$unit" 2>&1)"
  case "$state" in
    active|activating) ok "$unit  ($state, $enabled)" ;;
    inactive)
      # oneshot/timer Services dürfen inactive sein, das ist ihr Normalzustand
      if [[ "$unit" == *.timer || "$unit" == *youtube-fetch.service ]]; then
        ok "$unit  ($state, $enabled — oneshot/timer, OK)"
      elif [[ "$unit" == *daily-loop.service ]]; then
        # daily-loop ist oneshot — der wichtige State ist, ob die Background-Session lebt
        # Das prüfen wir unten in "background sessions"
        ok "$unit  ($state, $enabled — oneshot, Session-Status siehe unten)"
      else
        err "$unit  ($state, $enabled)"
      fi
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
    warn "ai-news snapshot-date  $snap_date (heute = $today)"
  fi
fi

hdr "background sessions (Claude daily loop)"
if command -v claude > /dev/null; then
  # Supervisor-Gesundheit: ein Binary-Auto-Upgrade killt den Daemon mid-uptime
  # und er kommt NICHT von selbst zurück. Dann ist die Session ein Zombie
  # (PID lebt, aber keine Cron-Wakeups / kein Auth-Refresh mehr).
  if claude daemon status 2>&1 | grep -qiE '^pid:|version:|uptime:'; then
    ok "claude daemon: läuft ($(claude daemon status 2>&1 | grep -iE '^version:' | head -1))"
  else
    err "claude daemon: NICHT erreichbar — Session ist vermutlich Zombie!"
    err "  → Fix: ./bin/start-daily-loop.sh   (reapt + startet neu)"
  fi
  # Briefing-Frische: wann lief der Daily-Loop zuletzt durch?
  ai_news="$PROJECT_DIR/dashboards/ai-news/index.html"
  if [ -f "$ai_news" ]; then
    bdate=$(grep -oE 'data-snapshot-date="[0-9-]+"' "$ai_news" | head -1 | sed 's/.*"\(.*\)"/\1/')
    today=$(date -I)
    if [ "$bdate" = "$today" ]; then
      ok "Briefing aktuell: $bdate (heute)"
    else
      age_days=$(( ( $(date -d "$today" +%s) - $(date -d "$bdate" +%s) ) / 86400 ))
      warn "Briefing veraltet: $bdate (${age_days} Tage alt) — Loop läuft nicht durch?"
    fi
  fi
  if [ -f "$HOME/.claude/daemon/roster.json" ]; then
    python3 - "$HOME/.claude/daemon/roster.json" <<'PY'
import json, os, sys
try:
    data = json.load(open(sys.argv[1]))
    raw = data.get('workers', data.get('sessions', [])) if isinstance(data, dict) else data
    entries = list(raw.values()) if isinstance(raw, dict) else (raw or [])
    if not entries:
        print("  (keine Sessions im roster)")
    else:
        for e in entries:
            if not isinstance(e, dict):
                continue
            name = (e.get('name')
                    or e.get('dispatch', {}).get('seed', {}).get('name')
                    or '(no name)')
            pid = e.get('pid')
            alive = '?'
            if pid:
                try: os.kill(pid, 0); alive = 'alive'
                except: alive = 'dead'
            short = (e.get('sessionId') or '')[:8]
            print(f"  · {name:30} pid={pid} ({alive}) sid={short}")
except Exception as ex:
    print(f"  ⚠ roster lesen fehlgeschlagen: {ex}")
PY
  else
    warn "kein roster.json — keine Background-Session bekannt"
  fi
else
  warn "claude binary nicht im PATH"
fi

hdr "summary"
if [ "$errors" -eq 0 ]; then
  printf "  \033[32m✓ alles im grünen Bereich\033[0m\n"
  exit 0
else
  printf "  \033[31m✗ %d Probleme\033[0m — siehe oben\n" "$errors"
  exit 1
fi
