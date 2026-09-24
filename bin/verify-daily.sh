#!/usr/bin/env bash
#
# verify-daily.sh — löst daily.service und watchdog.service einmal per systemd aus
# und prüft, dass systemd die Skripte ausführen KANN (Exec, Env, Pfade).
# daily.service ist idempotent: steht das heutige Briefing schon, endet er mit 0.
# Danach werden Startlimit und Tageszähler zurückgesetzt, damit Tests keine
# echten Versuche kosten. Braucht sudo für `systemctl start`/`reset-failed`.
#
set -uo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
for unit in ai-news-dashboard-daily.service ai-news-dashboard-watchdog.service; do
  echo "== $unit"
  sudo systemctl start "$unit" || true
  result="$(systemctl show "$unit" -p Result --value)"
  code="$(systemctl show "$unit" -p ExecMainStatus --value)"
  printf "   Result=%s ExecMainStatus=%s\n" "$result" "$code"
  journalctl -u "$unit" -n 8 --no-pager -o cat | sed 's/^/   | /'
  case "$code" in
    0) ;;
    203|126|127) fail=1; echo "   ✗ Exec-Problem (203 SELinux/Pfad, 126/127 Binary)" ;;
    *) echo "   ⚠ Skript lief, endete mit $code — Grund siehe Journal (kein Exec-Problem)" ;;
  esac
done
sudo systemctl reset-failed ai-news-dashboard-daily.service 2>/dev/null || true
"$PROJECT_DIR/bin/run-daily.sh" --reset-attempts
if [ "$fail" -eq 0 ]; then echo "✓ PASS — systemd kann Oneshot und Watchdog ausführen"; else echo "✗ FAIL"; exit 1; fi
