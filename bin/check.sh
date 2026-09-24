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
    failed)
      if [[ "$unit" == *daily-loop.service ]]; then
        err "$unit  (failed seit letztem Boot — Boot-Start scheiterte damals; der Healthcheck-Timer heilt unabhängig davon. Aufräumen: sudo systemctl reset-failed $unit)"
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
    age_days=$(( ( $(date -d "$today" +%s) - $(date -d "$snap_date" +%s) ) / 86400 ))
    if [ "$age_days" -le 1 ]; then
      ok "ai-news snapshot-date  $snap_date (gestern — Tageslauf steht noch aus)"
    else
      warn "ai-news snapshot-date  $snap_date (${age_days} Tage alt, heute = $today)"
    fi
  fi
fi

hdr "background sessions (Claude daily loop)"
LAUNCHER="$PROJECT_DIR/bin/start-daily-loop.sh"
STATE_DIR="${STATE_DIR:-$HOME/.local/state/ai-news-dashboard}"
if [ -x "$LAUNCHER" ]; then
  # Der Watchdog-Launcher ist die einzige Wahrheit: Auth, Daemon, Session,
  # Briefing-Frische. --dry-run prüft nur. Exit 0 = gesund, 1 = würde heilen
  # (macht der nächste Timer-Lauf), 2 = braucht einen Menschen.
  wd_out="$("$LAUNCHER" --dry-run 2>&1)"; wd_rc=$?
  printf '%s\n' "$wd_out" | grep -v 'dry-run: nur prüfen' | sed 's/^  \[start-daily-loop\] /    /'
  case "$wd_rc" in
    0) ok "Watchdog: gesund" ;;
    1) warn "Watchdog: würde heilen — passiert beim nächsten Timer-Lauf (≤ 30 Min) oder sofort via ./bin/start-daily-loop.sh" ;;
    *) err "Watchdog: braucht dich (exit $wd_rc) — siehe ALARM oben" ;;
  esac
else
  err "Watchdog-Launcher fehlt oder ist nicht ausführbar: $LAUNCHER"
fi

# Selbstheiler-Unit: feuert der Timer UND läuft der Launcher durch?
# (is-active am Timer allein sagt nur, dass er feuert — nicht, dass er heilt.)
hc_active="$(systemctl is-active ai-news-dashboard-healthcheck.timer 2>&1)"
hc_result="$(systemctl show ai-news-dashboard-healthcheck.service -p Result --value 2>/dev/null)"
hc_code="$(systemctl show ai-news-dashboard-healthcheck.service -p ExecMainStatus --value 2>/dev/null)"
hc_last="$(systemctl show ai-news-dashboard-healthcheck.service -p ExecMainExitTimestamp --value 2>/dev/null)"
if [ "$hc_active" != "active" ]; then
  err "healthcheck.timer ist $hc_active — Selbstheiler feuert nicht: sudo systemctl enable --now ai-news-dashboard-healthcheck.timer"
elif [ "$hc_result" = "success" ] && [ "$hc_code" = "0" ]; then
  ok "healthcheck.timer aktiv, letzter Lauf ok (${hc_last:-noch keiner})"
elif [ "$hc_code" = "1" ]; then
  warn "healthcheck.timer aktiv, letzter Lauf wartet/heilt (ExecMainStatus=1, ${hc_last:-?}) — journalctl -u ai-news-dashboard-healthcheck.service -n 20"
else
  err "healthcheck.timer aktiv, aber letzter Lauf: Result=$hc_result ExecMainStatus=$hc_code (${hc_last:-?}) — journalctl -u ai-news-dashboard-healthcheck.service -n 20"
fi

# Letzter Watchdog-Alarm (wird bei einem gesunden Lauf gelöscht)
if [ -f "$STATE_DIR/last-alert" ]; then
  err "letzter Watchdog-Alarm [$(sed -n 1p "$STATE_DIR/last-alert")] $(sed -n 2p "$STATE_DIR/last-alert"): $(sed -n 3p "$STATE_DIR/last-alert")"
fi

# Roster-Übersicht (informativ)
if [ -f "$HOME/.claude/daemon/roster.json" ]; then
  python3 - "$HOME/.claude/daemon/roster.json" <<'PY2'
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
                except Exception: alive = 'dead'
            short = (e.get('sessionId') or '')[:8]
            print(f"  · {name:30} pid={pid} ({alive}) sid={short} cli=v{e.get('cliVersion', '?')}")
except Exception as ex:
    print(f"  ⚠ roster lesen fehlgeschlagen: {ex}")
PY2
else
  warn "kein roster.json — keine Background-Session bekannt"
fi

hdr "summary"
if [ "$errors" -eq 0 ]; then
  printf "  \033[32m✓ alles im grünen Bereich\033[0m\n"
  exit 0
else
  printf "  \033[31m✗ %d Probleme\033[0m — siehe oben\n" "$errors"
  exit 1
fi
