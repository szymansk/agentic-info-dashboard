#!/usr/bin/env bash
#
# verify-daily.sh — löst daily.service und watchdog.service einmal per systemd aus
# und prüft, dass systemd die Skripte ausführen KANN (Exec, Env, Pfade).
# daily.service ist NUR dann idempotent (endet sofort mit 0, ohne echten Lauf),
# wenn das heutige Briefing schon steht/gepusht ist. Steht es noch nicht, würde
# `systemctl start` den vollen Produktivlauf auslösen (claude -p, Commit, Push;
# bis zu 90 Minuten, danach Restart-Zyklen, echte Alerts bei Fehlschlag) und
# `--reset-attempts` danach einen echten Tageszähler löschen. Deshalb bricht
# dieses Skript OHNE --full-run vorher ab, wenn das heutige Briefing fehlt.
# Braucht sudo für `systemctl start`/`reset-failed`.
#
# Usage: bin/verify-daily.sh [--full-run]
#   --full-run   Lauf erzwingen, auch wenn das heutige Briefing noch fehlt
#                (bewusster voller Produktivlauf statt reinem Exec-Test)
#
set -uo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/lib-daily.sh
. "$PROJECT_DIR/bin/lib-daily.sh"

FULL_RUN=0
case "${1:-}" in
  --full-run) FULL_RUN=1 ;;
  "") ;;
  *) echo "usage: verify-daily.sh [--full-run]" >&2; exit 64 ;;
esac

if [ "$FULL_RUN" != 1 ]; then
  cur="$(snapshot_date "$PROJECT_DIR/dashboards/ai-news/index.html")"
  if [ "$cur" != "$(today)" ]; then
    echo "✗ Heutiges Briefing ($(today)) steht noch nicht (aktuell: ${cur:-unbekannt})."
    echo "  verify-daily.sh testet standardmäßig nur den idempotenten Pfad (Briefing schon aktuell"
    echo "  → daily.service endet sofort mit 0). Ohne aktuelles Briefing würde 'systemctl start"
    echo "  ai-news-dashboard-daily.service' den vollen Produktivlauf auslösen (claude -p, Commit,"
    echo "  Push; bis zu 90 Minuten, danach Restart-Zyklen, echte Alerts bei Fehlschlag) und"
    echo "  --reset-attempts danach einen echten Tageszähler löschen."
    echo "  → entweder nach dem heutigen Lauf erneut ausführen, oder bewusst: verify-daily.sh --full-run"
    exit 2
  fi
fi

fail=0
for unit in ai-news-dashboard-daily.service ai-news-dashboard-watchdog.service; do
  echo "== $unit"
  sudo systemctl start "$unit" || true
  result="$(systemctl show "$unit" -p Result --value)"
  code="$(systemctl show "$unit" -p ExecMainStatus --value)"
  printf "   Result=%s ExecMainStatus=%s\n" "$result" "$code"
  journalctl -u "$unit" -n 8 --no-pager -o cat | sed 's/^/   | /'
  if [ "$result" = "start-limit-hit" ]; then
    fail=1
    echo "   ✗ Start-Limit erreicht (ExecMainStatus ist dabei veraltet) — 'sudo systemctl reset-failed $unit' und erneut versuchen"
    continue
  fi
  case "$code" in
    0) ;;
    203|126|127) fail=1; echo "   ✗ Exec-Problem (203 SELinux/Pfad, 126/127 Binary)" ;;
    *) echo "   ⚠ Skript lief, endete mit $code — Grund siehe Journal (kein Exec-Problem)" ;;
  esac
done
sudo systemctl reset-failed ai-news-dashboard-daily.service 2>/dev/null || true
"$PROJECT_DIR/bin/run-daily.sh" --reset-attempts
if [ "$fail" -eq 0 ]; then echo "✓ PASS — systemd kann Oneshot und Watchdog ausführen"; else echo "✗ FAIL"; exit 1; fi
