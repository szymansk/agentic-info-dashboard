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

# ── Klassifikation (Spec 5.2) ─────────────────────────────────────────
# classify_result <json-datei> → "<code> <ART> <text>"
#   0 OK · 3 AUTH (401/403) · 8 API (400/404, Budget) · 7 BLOCKED · 5 RUN (Rest, kein JSON)
classify_result() {
  python3 - "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
    assert isinstance(d, dict)
except Exception as e:
    print("5 RUN keine auswertbare JSON-Ausgabe (%s)" % type(e).__name__); sys.exit(0)
st = d.get("api_error_status"); tr = d.get("terminal_reason")
res = d.get("result") or ""
short = res.replace("\n", " ")[:160] or str(d.get("errors") or "")[:160]
if d.get("is_error") or tr not in (None, "completed"):
    if st in (401, 403): print(f"3 AUTH api {st}: {short}")
    elif st in (400, 404) or tr == "budget_exhausted": print(f"8 API {tr or st}: {short}")
    else: print(f"5 RUN {tr or st}: {short}")
    sys.exit(0)
blocked = [l.strip() for l in res.splitlines() if l.strip().startswith("BLOCKED:")]
if blocked: print("7 BLOCKED " + blocked[0][8:].strip()[:160]); sys.exit(0)
print("0 OK")
PY
}

# Eigener Dirt = generierte Pfade; alles andere ist fremd (Spec 5.2).
OWN_DIRT_PATHS=(dashboards/ai-news dashboards/it-services docs)

# classify_dirt: liest `git status --porcelain --untracked-files=all` von stdin
# → clean | own | foreign
classify_dirt() {
  local line path own=0 foreign=0 p match
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    path="${line:3}"
    path="${path##* -> }"                 # Rename: Zielpfad
    path="${path#\"}"; path="${path%\"}"  # Quoting bei Sonderzeichen
    match=0
    for p in "${OWN_DIRT_PATHS[@]}"; do
      [[ "$path" == "$p/"* ]] && match=1
    done
    if [ "$match" = 1 ]; then own=1; else foreign=1; fi
  done
  if [ "$foreign" = 1 ]; then echo foreign
  elif [ "$own" = 1 ]; then echo own
  else echo clean; fi
}
