#!/usr/bin/env bash
#
# deploy.sh — Build the static site and push to GitHub.
#
# Aufgerufen von:
#   - systemd youtube-fetch.service (nach Skript-Lauf)
#   - DAILY_UPDATE.md Step 6 (Claude background session, nach Briefing-Update)
#   - Manuell wenn man eine Änderung sofort live haben will
#
# Idempotent: läuft den Build, committed nur wenn sich was geändert hat,
# pusht nur dann. Kein-op wenn nichts neu ist.
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

MSG="${1:-auto: rebuild $(date -I)}"

# 1. Build static site → docs/
python3 scripts/build-pages.py

# 2. Stage everything (docs/ + any source changes)
git add -A

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
