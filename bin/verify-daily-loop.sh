#!/usr/bin/env bash
#
# verify-daily-loop.sh — prüft, ob der systemd-Selbstheiler den Launcher jetzt
# fehlerfrei ausführen kann (nach dem SELinux- + PATH-Fix).
#
# Löst den Healthcheck-Service einmal aus und liest sein Ergebnis. Der Launcher
# ist idempotent: läuft die Session schon, exitet er 0 ("bereits aktiv"), es
# wird nichts doppelt gestartet.
#
# Nur das `systemctl start` braucht root → dafür ein einziger sudo-Prompt.
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="$PROJECT_DIR/bin/start-daily-loop.sh"
# Beide Self-Heal-Units testen: healthcheck (alle 30 Min) + daily-loop (Boot).
# Der idempotente Start räumt zugleich einen veralteten Failed-Status weg.
UNITS="ai-news-dashboard-healthcheck.service ai-news-dashboard-daily-loop.service"

echo "== 1. SELinux-Label am Launcher (soll bin_t sein) =="
ls -Z "$LAUNCHER"

echo
echo "== 2. systemd Live-Test — Self-Heal-Units auslösen (braucht sudo) =="
fail=0
for unit in $UNITS; do
  sudo systemctl start "$unit" || true
  result="$(systemctl show "$unit" -p Result --value)"
  code="$(systemctl show "$unit" -p ExecMainStatus --value)"
  printf "  %-42s Result=%s ExecMainStatus=%s\n" "$unit" "$result" "$code"
  # Watchdog-Exit-Codes: 0 gesund/geheilt, 1 wartet (Session arbeitet/Cooldown),
  # 2 braucht Mensch (Auth/stuck). Alle drei heißen: systemd KONNTE den Launcher
  # ausführen — nur das prüft dieses Script. 203 = SELinux, 126/127 = PATH/exec.
  case "$code" in
    0|1|2) ;;
    *) fail=1 ;;
  esac
  [ "$code" = "2" ] && journalctl -u "$unit" -n 5 --no-pager -o cat | sed 's/^/      /'
done

echo
echo "== 3. Background-Session lebt? =="
"$PROJECT_DIR/bin/loop.sh" status 2>&1 | grep -E 'name|short-id|pid|started' || true

echo
if [ "$fail" -eq 0 ]; then
  echo "✓ PASS — systemd kann den Launcher ausführen. Watchdog ist scharf."
  echo "    (ExecMainStatus 1 = wartet, 2 = braucht dich — Details: ./bin/check.sh)"
else
  echo "✗ FAIL — mind. eine Unit hat ExecMainStatus außerhalb 0/1/2"
  echo "    203     = SELinux exec-denied (Label prüfen, Schritt 1)"
  echo "    126/127 = Binary/PATH → journalctl -u <unit> -n 20"
  exit 1
fi
