#!/usr/bin/env bash
#
# deploy.sh — Build the static site and push to GitHub.
#
# Aufgerufen von:
#   - systemd youtube-fetch.service (nach Skript-Lauf)
#   - DAILY_UPDATE.md Schritt 7 (täglicher claude -p-Oneshot, nach Briefing-Update)
#   - Manuell wenn man eine Änderung sofort live haben will
#
# Idempotent: läuft den Build, committed nur wenn sich was geändert hat,
# pusht nur dann. Kein-op wenn nichts neu ist.
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

# SELinux-Insurance: der Launcher muss von systemd (init_t) ausführbar bleiben.
# Ein Git-Rewrite/Checkout kann sein SELinux-Label auf user_home_t zurücksetzen
# → der systemd-Selbstheiler scheitert dann still mit 203/EXEC "Permission
# denied", das Briefing steht beim nächsten Idle-Exit. restorecon setzt das
# einmalig via `sudo semanage fcontext -a -t bin_t …` hinterlegte bin_t-Label
# wieder. No-op auf Nicht-SELinux-Systemen; nie fatal.
# Alle bin/-Skripte tragen per semanage-Verzeichnisregel bin_t (Defense-in-Depth;
# die Units rufen /usr/bin/bash <skript>, sind also nicht auf das Label angewiesen).
if command -v restorecon >/dev/null 2>&1; then
  restorecon -R "$PROJECT_DIR/bin" 2>/dev/null || true
fi

MSG="${1:-auto: rebuild $(date -I)}"

# 1. Build static site → docs/
python3 scripts/build-pages.py

# 2. Nur generierte Inhalte stagen. Infra-Änderungen (bin/, scripts/, *.md)
#    werden bewusst nicht mitgenommen: sie gehören in eigene Commits, und ein
#    manipulierter Lauf soll nichts Beliebiges ins öffentliche Repo schieben.
git add dashboards docs

# 3. Commit only if there's something to commit
if git diff --cached --quiet; then
  echo "→ keine Änderungen, kein Commit"
  exit 0
fi

git commit -m "$MSG"
echo "→ commit: $(git log -1 --oneline)"

# 4. Push
git push origin main
echo "→ pushed to origin/main"
