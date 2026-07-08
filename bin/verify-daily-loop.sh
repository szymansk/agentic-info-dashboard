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
  [ "$result" = "success" ] && [ "$code" = "0" ] || fail=1
done

echo
echo "== 3. Background-Session lebt? =="
"$PROJECT_DIR/bin/loop.sh" status 2>&1 | grep -E 'name|short-id|pid|started' || true

echo
if [ "$fail" -eq 0 ]; then
  echo "✓ PASS — systemd kann den Launcher fehlerfrei ausführen. Selbstheiler ist scharf."
else
  echo "✗ FAIL — mind. eine Unit hat Result!=success / ExecMainStatus!=0"
  echo "    203 = SELinux exec-denied (Label prüfen, Schritt 1)"
  echo "    1   = Script lief, brach selbst ab → journalctl -u <unit> -n 20"
  exit 1
fi
