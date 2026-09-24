#!/usr/bin/env bash
#
# start-daily-loop.sh — Watchdog + Launcher für die Background-Claude-Session
# "daily-ai-update" (täglicher Briefing-Loop des ai-news-dashboards).
#
# Wird von systemd aufgerufen (Boot: daily-loop.service; alle 30 Min:
# healthcheck.timer) und kann jederzeit von Hand laufen. Idempotent.
#
# Prüft in dieser Reihenfolge und heilt, was heilbar ist:
#   1. Auth      `claude auth status` → nicht eingeloggt? → ALARM, Exit 2.
#                Headless kann NICHT re-authentifizieren; nur ein interaktives
#                `claude` + /login auf dieser Maschine hilft. Läuft der
#                Refresh-Token bald ab → Vorwarnung.
#   2. Daemon    `claude daemon status` (Output wird gecaptured — KEIN `grep -q`
#                auf der Pipe, das liefert mit pipefail einen Fehlalarm, sobald
#                die Ausgabe mehr als einen write() lang ist; seit CLI 2.1.243).
#                Tot? → `claude daemon stop --any` (transiente Daemons
#                brauchen --any, ohne wird nichts gestoppt).
#   3. Session   Roster + PID → lebt?
#   4. ERGEBNIS  Briefing-Datum in dashboards/ai-news/index.html. Älter als
#                MAX_BRIEFING_AGE_DAYS und Session idle → Zombie → Neustart
#                (mit Cooldown + Tageslimit; danach ALARM, Exit 2). Eine
#                beschäftigte Session wird erst ersetzt, wenn das Briefing
#                ≥ HARD_STALE_DAYS alt ist UND sie länger als ein Cooldown
#                läuft (hatte also ihre Chance). Das ist
#                die einzige Prüfung, die alle bisherigen Ausfallarten fängt:
#                sie misst das Ergebnis, nicht den Mechanismus.
#
# Optionen:  --dry-run | --status   nur prüfen + Entscheidung loggen, nichts
#                                   ändern (nutzt check.sh)
# Exit:      0 = gesund oder geheilt · 1 = wartet (Cooldown/Session arbeitet)
#            2 = braucht einen Menschen (Auth weg / Neustarts erschöpft)
#
# Alarme landen im Journal (`journalctl -t ai-news-watchdog`), in
# ~/.local/state/ai-news-dashboard/alerts.log (+ last-alert für check.sh) und
# optional bei ntfy (siehe watchdog.env).
#
# Optionale Konfig: ~/.config/ai-news-dashboard/watchdog.env (wird gesourced,
# chmod 600 empfohlen). Beispiel:
#   NTFY_TOPIC=mein-geheimes-topic      # Alarm → https://ntfy.sh/<topic>
#   NTFY_URL=https://ntfy.example/x     # alternativ komplette URL
#   CLAUDE_MODEL=claude-opus-4-8        # Modell-Pin überschreiben
#   MAX_BRIEFING_AGE_DAYS=2             # ab wann „veraltet"
#   CLAUDE_CODE_OAUTH_TOKEN=…           # langlebiger Token aus `claude setup-token`
#
set -euo pipefail

SESSION_NAME="${SESSION_NAME:-daily-ai-update}"
PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROMPT_FILE="$PROJECT_DIR/DAILY_UPDATE.md"
ROSTER="$HOME/.claude/daemon/roster.json"
CREDENTIALS="$HOME/.claude/.credentials.json"
STATE_DIR="${STATE_DIR:-$HOME/.local/state/ai-news-dashboard}"
ENV_FILE="${ENV_FILE:-$HOME/.config/ai-news-dashboard/watchdog.env}"

# Optionale Konfig laden (exportiert, damit z.B. CLAUDE_CODE_OAUTH_TOKEN bei
# der Session ankommt).
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

MAX_BRIEFING_AGE_DAYS="${MAX_BRIEFING_AGE_DAYS:-2}"   # ab hier gilt das Briefing als veraltet
HARD_STALE_DAYS="${HARD_STALE_DAYS:-5}"               # ab hier wird auch eine „beschäftigte" Session neu gestartet
BUSY_WINDOW_SEC="${BUSY_WINDOW_SEC:-2700}"            # 45 Min ohne Transcript-Aktivität = idle
RESTART_COOLDOWN_SEC="${RESTART_COOLDOWN_SEC:-21600}" # 6 h zwischen zwei Neustarts
MAX_RESTARTS_PER_DAY="${MAX_RESTARTS_PER_DAY:-3}"
TOKEN_WARN_DAYS="${TOKEN_WARN_DAYS:-5}"               # Vorwarnung vor Refresh-Token-Ablauf
ALERT_REPEAT_SEC="${ALERT_REPEAT_SEC:-43200}"         # externe Alarme je Art max. alle 12 h

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run|--status) DRY_RUN=1 ;;
    -h|--help) sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unbekannte Option: $arg" >&2; exit 64 ;;
  esac
done

# claude-Binary PATH-unabhängig auflösen: unter systemd fehlt ~/.local/bin im
# PATH (die Units setzen kein Environment=PATH).
if [ -z "${CLAUDE_BIN:-}" ]; then
  for _cand in \
    "$(command -v claude 2>/dev/null || true)" \
    "$HOME/.local/bin/claude" \
    "/usr/local/bin/claude" \
    "/usr/bin/claude"; do
    if [ -n "$_cand" ] && [ -x "$_cand" ]; then CLAUDE_BIN="$_cand"; break; fi
  done
fi
CLAUDE_BIN="${CLAUDE_BIN:-/usr/bin/claude}"
# Modell fest verdrahten — nie vom interaktiven Default in settings.json
# abhängen (der kann für den Account unverfügbar sein, z.B. Mythos-gated).
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-opus-4-8}"

# Transcript-Pfad der Session: ~/.claude/projects/<slug>/<sid>.jsonl,
# slug = Projektpfad mit '/' und '_' → '-'.
SLUG="$(printf '%s' "$PROJECT_DIR" | sed 's#[/_]#-#g')"

log()  { printf "  [start-daily-loop] %s\n" "$*"; }
warn() { printf "  [start-daily-loop] ⚠ %s\n" "$*"; }
dry()  { [ "$DRY_RUN" = 1 ] && printf "  [start-daily-loop] [dry-run] würde: %s\n" "$*"; }

BRIEFING_DATE="unbekannt"
BRIEFING_AGE=999
AUTH_LOGGED_IN="no"
TOKEN_DAYS_LEFT=""
DAEMON_VERSION=""
LAST_ACTIVITY=0
RESTART_BLOCK=""

# ── Alarmierung ──────────────────────────────────────────────────────
alert() {  # alert <ART> <Text>
  local kind="$1"; shift
  local msg="$*"
  printf "  [start-daily-loop] ✗ ALARM [%s] %s\n" "$kind" "$msg" >&2
  logger -p user.err -t ai-news-watchdog "[$kind] $msg" 2>/dev/null || true
  [ "$DRY_RUN" = 1 ] && return 0
  mkdir -p "$STATE_DIR"
  printf "%s\t%s\t%s\n" "$(date -Is)" "$kind" "$msg" >> "$STATE_DIR/alerts.log"
  printf "%s\n%s\n%s\n" "$kind" "$(date -Is)" "$msg" > "$STATE_DIR/last-alert"
  # externe Zustellung gedrosselt (je Art höchstens alle ALERT_REPEAT_SEC)
  local stamp="$STATE_DIR/alert-sent.$kind"
  if [ -f "$stamp" ] && [ $(( $(date +%s) - $(stat -c %Y "$stamp") )) -lt "$ALERT_REPEAT_SEC" ]; then
    return 0
  fi
  if [ -n "${NTFY_URL:-}" ] || [ -n "${NTFY_TOPIC:-}" ]; then
    local url="${NTFY_URL:-https://ntfy.sh/${NTFY_TOPIC:-}}"
    if curl -fsS -m 10 -H "Title: ai-news-dashboard [$kind]" -H "Priority: high" \
         -d "$msg" "$url" >/dev/null 2>&1; then
      log "  Alarm via ntfy zugestellt"
    else
      warn "ntfy-Zustellung fehlgeschlagen ($url)"
    fi
  fi
  touch "$stamp"
}
clear_alert() { [ "$DRY_RUN" = 1 ] || rm -f "$STATE_DIR/last-alert"; }

# ── 1. Auth ──────────────────────────────────────────────────────────
auth_check() {
  local out
  out="$("$CLAUDE_BIN" auth status 2>&1 || true)"
  AUTH_LOGGED_IN="$(python3 -c '
import json, sys
try:
    print("yes" if json.loads(sys.argv[1]).get("loggedIn") else "no")
except Exception:
    print("no")' "$out")"
  TOKEN_DAYS_LEFT="$(python3 - "$CREDENTIALS" <<'PY'
import json, sys, time
try:
    o = json.load(open(sys.argv[1])).get("claudeAiOauth", {})
    v = o.get("refreshTokenExpiresAt")
    print(int((v / 1000 - time.time()) // 86400) if v else "")
except Exception:
    print("")
PY
)"
}

# ── 2. Supervisor-Daemon ─────────────────────────────────────────────
daemon_healthy() {
  local out
  # Output vollständig einsammeln. NICHT `status | grep -q` — grep -q beendet
  # die Pipe früh, claude bekommt EPIPE, exit≠0, pipefail → „unhealthy".
  out="$("$CLAUDE_BIN" daemon status 2>&1)" || return 1
  grep -qE '^pid:' <<<"$out" || return 1
  # Neuere CLIs melden den Control-Socket separat; wenn die Zeile da ist,
  # muss sie „reachable" sagen — sonst ist die Session ein Zombie.
  if grep -qE 'control\.sock:' <<<"$out"; then
    grep -qE 'control\.sock: +reachable' <<<"$out" || return 1
  fi
  DAEMON_VERSION="$(grep -E '^version:' <<<"$out" | awk '{print $2}' | head -1)"
  return 0
}

reap_daemon() {
  log "reape Supervisor + verwaiste Worker via 'claude daemon stop --any' …"
  "$CLAUDE_BIN" daemon stop --any 2>&1 | sed 's/^/    /' || true
  sleep 2
}

# ── 3. Session im Roster ─────────────────────────────────────────────
find_session() {  # druckt: "<sid> <pid> <alive:1|0> <startedAt-epoch>" oder "- - 0 0"
  [ -f "$ROSTER" ] || { echo "- - 0 0"; return; }
  python3 - "$ROSTER" "$SESSION_NAME" <<'PY'
import json, os, sys
roster_path, name = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(roster_path))
except Exception:
    print("- - 0 0"); sys.exit(0)
raw = data.get('workers', data.get('sessions', [])) if isinstance(data, dict) else data
entries = list(raw.values()) if isinstance(raw, dict) else (raw or [])
found = None
for e in entries:
    if not isinstance(e, dict):
        continue
    entry_name = e.get('name') or e.get('dispatch', {}).get('seed', {}).get('name')
    if entry_name != name:
        continue
    pid = e.get('pid') or 0
    alive = 0
    if pid:
        try:
            os.kill(pid, 0); alive = 1
        except (OSError, ProcessLookupError):
            pass
    sid = e.get('sessionId') or e.get('id') or '-'
    started = int((e.get('startedAt') or 0) / 1000)
    found = (sid, pid, alive, started)
    if alive:
        break
print(f"{found[0]} {found[1]} {found[2]} {found[3]}" if found else "- - 0 0")
PY
}

cleanup_roster() {  # tote Einträge mit unserem Namen entfernen
  [ -f "$ROSTER" ] || return 0
  local stale sid
  stale="$(python3 - "$ROSTER" "$SESSION_NAME" <<'PY' 2>/dev/null || true
import json, sys
roster_path, name = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(roster_path))
except Exception:
    sys.exit(0)
raw = data.get('workers', data.get('sessions', [])) if isinstance(data, dict) else data
entries = list(raw.values()) if isinstance(raw, dict) else (raw or [])
for e in entries:
    if isinstance(e, dict):
        entry_name = e.get('name') or e.get('dispatch', {}).get('seed', {}).get('name')
        if entry_name == name:
            sid = e.get('sessionId') or e.get('id') or ''
            if sid: print(sid)
PY
)"
  for sid in $stale; do
    log "  räume Roster-Eintrag $sid auf"
    "$CLAUDE_BIN" rm "$sid" 2>&1 | sed 's/^/    /' || true
  done
}

session_busy() {  # $1=sid → 0 wenn Transcript/Timeline in den letzten BUSY_WINDOW_SEC geschrieben wurde
  local sid="$1" f m newest=0
  for f in "$HOME/.claude/projects/$SLUG/$sid.jsonl" "$HOME/.claude/jobs/${sid%%-*}/timeline.jsonl"; do
    [ -f "$f" ] || continue
    m="$(stat -c %Y "$f")"
    [ "$m" -gt "$newest" ] && newest="$m"
  done
  LAST_ACTIVITY="$newest"
  [ "$newest" -gt 0 ] && [ $(( $(date +%s) - newest )) -lt "$BUSY_WINDOW_SEC" ]
}

# ── 4. Ergebnis: Briefing-Frische ────────────────────────────────────
read_briefing_age() {  # setzt BRIEFING_DATE + BRIEFING_AGE (Tage); keine Subshell!
  local html="$PROJECT_DIR/dashboards/ai-news/index.html" d
  d="$(grep -oE 'data-snapshot-date="[0-9]{4}-[0-9]{2}-[0-9]{2}"' "$html" 2>/dev/null \
       | head -1 | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' || true)"
  if [ -z "$d" ]; then BRIEFING_DATE="unbekannt"; BRIEFING_AGE=999; return; fi
  BRIEFING_DATE="$d"
  BRIEFING_AGE=$(( ( $(date -d "$(date -I)" +%s) - $(date -d "$d" +%s) ) / 86400 ))
}

# ── Neustart-Budget ──────────────────────────────────────────────────
restart_allowed() {
  local f="$STATE_DIR/restarts.log" now last n_day
  now="$(date +%s)"
  [ -f "$f" ] || return 0
  last="$(tail -1 "$f" | cut -f1)"
  if [ -n "$last" ] && [ $(( now - last )) -lt "$RESTART_COOLDOWN_SEC" ]; then
    RESTART_BLOCK="Cooldown, noch $(( (RESTART_COOLDOWN_SEC - (now - last)) / 60 )) Min"
    return 1
  fi
  n_day="$(awk -F'\t' -v t="$(( now - 86400 ))" '$1 > t' "$f" | wc -l)"
  if [ "$n_day" -ge "$MAX_RESTARTS_PER_DAY" ]; then
    RESTART_BLOCK="Tageslimit erreicht ($n_day Neustarts in 24 h)"
    return 1
  fi
  return 0
}
record_restart() {
  [ "$DRY_RUN" = 1 ] && return 0
  mkdir -p "$STATE_DIR"
  printf "%s\t%s\t%s\n" "$(date +%s)" "$(date -Is)" "$1" >> "$STATE_DIR/restarts.log"
}

# ── Session stoppen / starten ────────────────────────────────────────
stop_session() {  # <sid> <pid>
  local sid="$1" pid="$2" i
  log "stoppe Session $sid (pid=$pid) …"
  "$CLAUDE_BIN" stop "$sid" 2>&1 | sed 's/^/    /' || true
  for i in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  if kill -0 "$pid" 2>/dev/null; then
    warn "PID $pid lebt noch → SIGTERM"; kill "$pid" 2>/dev/null || true; sleep 3
  fi
  if kill -0 "$pid" 2>/dev/null; then
    warn "PID $pid lebt immer noch → SIGKILL"; kill -9 "$pid" 2>/dev/null || true; sleep 1
  fi
  "$CLAUDE_BIN" rm "$sid" 2>&1 | sed 's/^/    /' || true
}

start_session() {
  local prompt
  prompt="/loop 24h Lies $PROMPT_FILE und führe den dort beschriebenen Daily-Update-Workflow für das ai-news-dashboard aus. Working directory ist $PROJECT_DIR. Halte an mit konkreter Frage, falls etwas blockiert. Am Ende eine einzeilige Status-Bilanz ausgeben."
  cd "$PROJECT_DIR"
  log "→ starte neue Background-Session '$SESSION_NAME' (model=$CLAUDE_MODEL)"
  log "   prompt-file: $PROMPT_FILE"
  # --dangerously-skip-permissions: der Loop arbeitet ohne Interaktion
  # (skipDangerousModePermissionPrompt in settings.json ist gesetzt).
  if "$CLAUDE_BIN" --bg \
       --name "$SESSION_NAME" \
       --model "$CLAUDE_MODEL" \
       --dangerously-skip-permissions \
       "$prompt" 2>&1 | sed 's/^/    /'; then
    log "✓ gestartet"
  else
    alert START "Background-Session konnte nicht gestartet werden (claude --bg exit≠0). journalctl -u ai-news-dashboard-healthcheck.service prüfen."
    exit 2
  fi
}

# ── Hauptablauf ──────────────────────────────────────────────────────
main() {
  [ "$DRY_RUN" = 1 ] && log "(dry-run: nur prüfen, nichts ändern)"

  if [ ! -x "$CLAUDE_BIN" ]; then
    alert BINARY "claude-Binary nicht gefunden ($CLAUDE_BIN)"; exit 2
  fi
  if [ ! -f "$PROMPT_FILE" ]; then
    alert PROMPT "DAILY_UPDATE.md fehlt unter $PROMPT_FILE"; exit 2
  fi

  read_briefing_age
  local age="$BRIEFING_AGE"

  # 1. Auth — ohne Login ist jeder Neustart sinnlos.
  auth_check
  if [ "$AUTH_LOGGED_IN" != "yes" ]; then
    alert AUTH "Claude-Login fehlt (Refresh-Token abgelaufen oder widerrufen); headless kann nicht re-authentifizieren. Fix: auf dieser Maschine 'claude' starten und /login ausführen. Briefing-Stand: $BRIEFING_DATE (${age} Tage alt)."
    exit 2
  fi
  if [ -n "$TOKEN_DAYS_LEFT" ]; then
    log "✓ eingeloggt (Refresh-Token noch ${TOKEN_DAYS_LEFT} Tage gültig)"
    if [ "$TOKEN_DAYS_LEFT" -le "$TOKEN_WARN_DAYS" ]; then
      alert TOKEN "Refresh-Token läuft in ${TOKEN_DAYS_LEFT} Tagen ab. Vorher auf dieser Maschine 'claude' starten und /login ausführen — sonst stoppt der Briefing-Loop danach still."
    fi
  else
    log "✓ eingeloggt"
  fi

  # 2. Daemon
  if daemon_healthy; then
    log "✓ Supervisor-Daemon läuft (v${DAEMON_VERSION:-?})"
  else
    warn "Supervisor-Daemon nicht erreichbar → Session wäre Zombie"
    if [ "$DRY_RUN" = 1 ]; then dry "daemon stop --any"; else reap_daemon; fi
  fi

  # 3. Session
  local sid pid alive started session_age
  read -r sid pid alive started <<<"$(find_session)"
  session_age=999999
  [ "${started:-0}" -gt 0 ] && session_age=$(( $(date +%s) - started ))

  # 4. Ergebnis
  if [ "$alive" = 1 ]; then
    if [ "$age" -lt "$MAX_BRIEFING_AGE_DAYS" ]; then
      log "✓ Session '$SESSION_NAME' aktiv (id=${sid%%-*}, pid=$pid), Briefing vom $BRIEFING_DATE (${age} Tage) — nichts zu tun"
      clear_alert
      exit 0
    fi
    warn "Briefing veraltet: $BRIEFING_DATE (${age} Tage), obwohl Session pid=$pid lebt"
    # Beschäftigte Session → warten. Ausnahme: Briefing ist seit HARD_STALE_DAYS
    # alt UND die Session läuft schon länger als ein Cooldown — dann hatte sie
    # ihre Chance und wird trotzdem ersetzt (fängt Sessions, deren Transcript
    # zwar wächst, die aber nie liefern).
    if session_busy "$sid" && { [ "$age" -lt "$HARD_STALE_DAYS" ] || [ "$session_age" -lt "$RESTART_COOLDOWN_SEC" ]; }; then
      log "Session (seit $(( session_age / 60 )) Min aktiv) hat vor $(( ( $(date +%s) - LAST_ACTIVITY ) / 60 )) Min gearbeitet — warte auf Abschluss"
      exit 1
    fi
    if ! restart_allowed; then
      alert STUCK "Briefing seit ${age} Tagen alt ($BRIEFING_DATE); Neustarts helfen nicht ($RESTART_BLOCK). Bitte ./bin/loop.sh log prüfen."
      exit 2
    fi
    if [ "$DRY_RUN" = 1 ]; then
      dry "Session ${sid%%-*} stoppen und neu starten (Zombie: letzte Transcript-Aktivität vor $(( ( $(date +%s) - LAST_ACTIVITY ) / 60 )) Min)"
      exit 1
    fi
    stop_session "$sid" "$pid"
    cleanup_roster
    record_restart "zombie: briefing $BRIEFING_DATE, ${age}d alt"
    start_session
    exit 0
  fi

  # keine lebende Session
  warn "keine lebende Session '$SESSION_NAME' (Briefing vom $BRIEFING_DATE, ${age} Tage)"
  if ! restart_allowed; then
    alert STUCK "Session tot und Neustart blockiert ($RESTART_BLOCK). Bitte journalctl -u ai-news-dashboard-healthcheck.service prüfen."
    exit 2
  fi
  if [ "$DRY_RUN" = 1 ]; then
    dry "Roster aufräumen und Session neu starten"
    exit 1
  fi
  cleanup_roster
  record_restart "keine lebende Session"
  start_session
  exit 0
}

main
