#!/usr/bin/env bash
#
# fix-selinux-launcher.sh — macht bin/start-daily-loop.sh wieder von systemd
# (init_t) ausführbar.
#
# Hintergrund
# ───────────
# Dateien unter /home tragen den SELinux-Kontext user_home_t. Unter Enforcing
# darf systemd (init_t) KEINE user_home_t-Datei ausführen. Damit scheitern
# BEIDE Auto-Restart-Pfade der Background-Session still mit 203/EXEC
# "Permission denied":
#   - ai-news-dashboard-daily-loop.service   (Boot)
#   - ai-news-dashboard-healthcheck.service  (30-Min-Selbstheiler)
# Symptom: Briefing steht nach einem Idle-Exit, YouTube/Server laufen weiter.
# Der Playbook-Check "Timer aktiv → Selbstheiler scharf" trügt hier: der Timer
# feuert, scheitert aber jedes Mal an SELinux.
#
# Fix: dem Launcher persistent das bin_t-Label geben (via semanage). bin_t darf
# init_t ausführen. deploy.sh hält das Label per restorecon nach Git-Rewrites
# gesund (ein Rewrite/Checkout setzt es sonst auf user_home_t zurück).
#
# Idempotent. Braucht root (semanage/restorecon/systemctl) → re-exec via sudo.
#
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT")")"
LAUNCHER="$PROJECT_DIR/bin/start-daily-loop.sh"
HEALTHCHECK_UNIT="ai-news-dashboard-healthcheck.service"

# ── root sicherstellen ──────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  echo "→ brauche root für semanage/restorecon/systemctl — re-exec via sudo …"
  exec sudo -- "$SCRIPT" "$@"
fi

# ── Werkzeuge + Ziel da? ────────────────────────────────────────────
for tool in semanage restorecon systemctl; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "❌ $tool fehlt (dnf install policycoreutils-python-utils)"; exit 1; }
done
[ -f "$LAUNCHER" ] || { echo "❌ Launcher nicht gefunden: $LAUNCHER"; exit 1; }

echo "== 1. persistente fcontext-Regel (bin_t) =="
if semanage fcontext -a -t bin_t "$LAUNCHER" 2>/dev/null; then
  echo "  → Regel angelegt"
else
  semanage fcontext -m -t bin_t "$LAUNCHER"
  echo "  → Regel aktualisiert (existierte bereits)"
fi

echo "== 2. Label anwenden =="
restorecon -v "$LAUNCHER"
ls -Z "$LAUNCHER"

echo "== 3. systemd exec-Test (Healthcheck-Service) =="
# Idempotent: start-daily-loop.sh erkennt die laufende Session und exitet 0.
systemctl start "$HEALTHCHECK_UNIT" || true
result="$(systemctl show "$HEALTHCHECK_UNIT" -p Result --value)"
code="$(systemctl show "$HEALTHCHECK_UNIT" -p ExecMainStatus --value)"
echo "  Result=$result ExecMainStatus=$code"

if [ "$result" = "success" ] && [ "$code" = "0" ]; then
  echo "✓ Fix greift — systemd kann den Launcher jetzt ausführen."
else
  echo "✗ noch nicht gut — Result=$result / ExecMainStatus=$code"
  echo "  (203 = weiterhin exec-denied). Denials prüfen:"
  echo "    journalctl -t audit | grep start-daily-loop | tail"
  exit 1
fi
