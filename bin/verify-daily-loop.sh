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
UNIT="ai-news-dashboard-healthcheck.service"

echo "== 1. SELinux-Label am Launcher (soll bin_t sein) =="
ls -Z "$LAUNCHER"

echo
echo "== 2. systemd Live-Test — Healthcheck-Service auslösen (braucht sudo) =="
sudo systemctl start "$UNIT" || true
result="$(systemctl show "$UNIT" -p Result --value)"
code="$(systemctl show "$UNIT" -p ExecMainStatus --value)"
echo "  Result=$result  ExecMainStatus=$code"

echo
echo "== 3. Background-Session lebt? =="
"$PROJECT_DIR/bin/loop.sh" status 2>&1 | grep -E 'name|short-id|pid|started' || true

echo
if [ "$result" = "success" ] && [ "$code" = "0" ]; then
  echo "✓ PASS — systemd kann den Launcher fehlerfrei ausführen. Selbstheiler ist scharf."
else
  echo "✗ FAIL — Result=$result / ExecMainStatus=$code"
  echo "    203 = SELinux exec-denied (Label prüfen, Schritt 1)"
  echo "    1   = Script lief, brach selbst ab → journalctl -u $UNIT -n 20"
  exit 1
fi
