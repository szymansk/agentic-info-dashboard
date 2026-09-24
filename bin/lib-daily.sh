# shellcheck shell=bash
#
# lib-daily.sh — gemeinsame Helfer für run-daily.sh, alert.sh, watchdog.sh,
# verify-briefing.sh. Nur sourcen, nie ausführen. Setzt KEIN set -e.
#
PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR="${STATE_DIR:-$HOME/.local/state/ai-news-dashboard}"
CONF_DIR="${CONF_DIR:-$HOME/.config/ai-news-dashboard}"
DAILY_ENV="${DAILY_ENV:-$CONF_DIR/daily.env}"
ALERT_ENV="${ALERT_ENV:-$CONF_DIR/alert.env}"
PAGES_URL="${PAGES_URL:-https://szymansk.github.io/agentic-info-dashboard/ai-news/}"
LOG_TAG="${LOG_TAG:-daily}"
mkdir -p "$STATE_DIR" 2>/dev/null || true

log()  { printf '  [%s] %s\n' "$LOG_TAG" "$*"; }
warn() { printf '  [%s] ⚠ %s\n' "$LOG_TAG" "$*" >&2; }
today() { date -I; }

# Env-Datei-Format: KEY=wert, Kommentare nur ganze Zeilen, kein export,
# keine Leerzeichen um '=', kein '#' im Wert (wäre für bash Teil des Werts).
env_file_valid() {
  [ -f "$1" ] || return 1
  if grep -vE '^[[:space:]]*(#|$)' "$1" | grep -qvE '^[A-Z_][A-Z0-9_]*=[^[:space:]#]*$'; then
    return 1
  fi
  return 0
}

# load_env <datei> → 0 geladen, 1 fehlt, 2 ungültig. Exportiert (set -a).
load_env() {
  [ -f "$1" ] || return 1
  env_file_valid "$1" || return 2
  set -a
  # shellcheck disable=SC1090
  . "$1"
  set +a
  return 0
}

# claude-Binary: ~/.local/bin zuerst (unter systemd nicht im PATH), dann PATH.
resolve_claude() {
  local c
  for c in "$HOME/.local/bin/claude" "$(command -v claude 2>/dev/null || true)" \
           /usr/local/bin/claude /usr/bin/claude; do
    if [ -n "$c" ] && [ -x "$c" ]; then printf '%s\n' "$c"; return 0; fi
  done
  return 1
}

snapshot_date() {  # <html> → YYYY-MM-DD oder leer
  grep -oE 'data-snapshot-date="[0-9]{4}-[0-9]{2}-[0-9]{2}"' "$1" 2>/dev/null \
    | head -1 | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' || true
}

days_between() {  # <früher> <später> → ganze Tage
  echo $(( ( $(date -d "$2" +%s) - $(date -d "$1" +%s) ) / 86400 ))
}

state_write() { mkdir -p "$STATE_DIR"; printf '%s\n' "$2" > "$STATE_DIR/$1"; }
state_read()  { [ -f "$STATE_DIR/$1" ] && cat "$STATE_DIR/$1" || true; }
