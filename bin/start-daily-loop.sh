#!/usr/bin/env bash
#
# Startet (oder reaktiviert) die Background-Claude-Session,
# die täglich das ai-news-dashboard aktualisiert.
#
# Idempotent: läuft die Session schon, passiert nichts.
# Wird primär von systemd beim Boot aufgerufen, kann aber auch
# von Hand laufen.
#
set -euo pipefail

SESSION_NAME="${SESSION_NAME:-daily-ai-update}"
PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROMPT_FILE="$PROJECT_DIR/DAILY_UPDATE.md"
# claude-Binary robust auflösen: unter systemd ist ~/.local/bin NICHT im PATH
# (die Units setzen kein Environment=PATH), deshalb reicht `command -v claude`
# allein nicht — sonst greift der /usr/bin/claude-Fallback, existiert nicht,
# und der Launcher bricht mit Exit 1 ab (203/EXEC-Fix legt genau das frei).
# Kandidaten der Reihe nach prüfen; erster ausführbarer gewinnt.
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
# Modell für den Loop fest verdrahten — NICHT vom interaktiven Default in
# ~/.claude/settings.json abhängig machen. Sonst bricht der unbeaufsichtigte
# Loop lautlos, wenn der Default auf ein (für den Account) nicht verfügbares
# Modell zeigt (z.B. claude-fable-5 / Mythos-gated). Überschreibbar per Env.
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-opus-4-8}"
ROSTER="$HOME/.claude/daemon/roster.json"

log() { printf "  [start-daily-loop] %s\n" "$*"; }

if [ ! -x "$CLAUDE_BIN" ]; then
  log "❌ claude binary nicht gefunden ($CLAUDE_BIN)"; exit 1
fi

if [ ! -f "$PROMPT_FILE" ]; then
  log "❌ DAILY_UPDATE.md fehlt unter $PROMPT_FILE"; exit 1
fi

# ── Supervisor-Daemon gesund? ───────────────────────────────────────
# Ein Binary-Auto-Upgrade killt den Supervisor mid-uptime ("binary was
# deleted — exiting for upgrade"). Er kommt NICHT von selbst zurück.
# Dann ist die Session ein Zombie: PID lebt, aber control.sock ist tot,
# keine Cron-Wakeups, kein Auth-Refresh mehr. Wir müssen das erkennen,
# sonst hält die PID-lebt-Prüfung unten die Session fälschlich für gesund.
daemon_healthy() {
  "$CLAUDE_BIN" daemon status 2>&1 | grep -qiE '^pid:|version:|uptime:'
}

if ! daemon_healthy; then
  log "⚠ Supervisor-Daemon nicht erreichbar (vermutlich nach Binary-Upgrade)."
  log "  reape verwaiste Worker via 'claude daemon stop' …"
  "$CLAUDE_BIN" daemon stop 2>&1 | sed 's/^/    /' || true
  # Nach dem Reap ist die Session-PID tot → die Prüfung unten erzwingt Neustart.
fi

# ── Prüfen, ob eine Session mit diesem Namen existiert + lebt ────────
existing_id=""
if [ -f "$ROSTER" ]; then
  existing_id=$(python3 - "$ROSTER" "$SESSION_NAME" <<'PY'
import json, os, sys
roster_path, name = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(roster_path))
except Exception:
    sys.exit(0)

# roster.json structure (v2.1.x): {proto, supervisorPid, workers: {short_id: {...}}}
# Älter / Variation: list or {workers: [...]} or {sessions: [...]}
raw = data.get('workers', data.get('sessions', [])) if isinstance(data, dict) else data
entries = list(raw.values()) if isinstance(raw, dict) else (raw or [])

for e in entries:
    if not isinstance(e, dict):
        continue
    # Name kann direkt am worker oder in dispatch.seed.name liegen
    entry_name = e.get('name') or e.get('dispatch', {}).get('seed', {}).get('name')
    if entry_name != name:
        continue
    pid = e.get('pid')
    alive = False
    if pid:
        try: os.kill(pid, 0); alive = True
        except (OSError, ProcessLookupError): pass
    sid = e.get('sessionId') or e.get('id') or ''
    if alive and sid:
        print(sid)
        break
PY
  )
fi

if [ -n "$existing_id" ]; then
  log "✓ Session '$SESSION_NAME' bereits aktiv (id=$existing_id) — nichts zu tun"
  exit 0
fi

# ── Sessions mit dem Namen, die nur stopped sind, aufräumen ──────────
# (Optional; vermeidet Roster-Verschmutzung)
if [ -f "$ROSTER" ]; then
  stale=$(python3 - "$ROSTER" "$SESSION_NAME" <<'PY' 2>/dev/null || true
import json, sys
roster_path, name = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(roster_path))
except Exception:
    sys.exit(0)
raw = data.get('workers', data.get('sessions', [])) if isinstance(data, dict) else data
entries = list(raw.values()) if isinstance(raw, dict) else (raw or [])
for e in entries:
    if not isinstance(e, dict):
        continue
    entry_name = e.get('name') or e.get('dispatch', {}).get('seed', {}).get('name')
    if entry_name == name:
        sid = e.get('sessionId') or e.get('id') or ''
        if sid:
            print(sid)
PY
  )
  for sid in $stale; do
    log "  räume verwaiste Session $sid auf"
    "$CLAUDE_BIN" rm "$sid" 2>&1 | sed 's/^/    /' || true
  done
fi

# ── Frische Session starten ──────────────────────────────────────────
cd "$PROJECT_DIR"
LOOP_PROMPT="/loop 24h Lies $PROMPT_FILE und führe den dort beschriebenen Daily-Update-Workflow für das ai-news-dashboard aus. Working directory ist $PROJECT_DIR. Halte an mit konkreter Frage, falls etwas blockiert. Am Ende eine einzeilige Status-Bilanz ausgeben."

log "→ starte neue Background-Session '$SESSION_NAME'"
log "   prompt-file: $PROMPT_FILE"
log "   cwd:         $PROJECT_DIR"

# --dangerously-skip-permissions: damit der Loop ohne Interaktion arbeiten
# darf. Muss einmalig interaktiv akzeptiert worden sein.
"$CLAUDE_BIN" --bg \
  --name "$SESSION_NAME" \
  --model "$CLAUDE_MODEL" \
  --dangerously-skip-permissions \
  "$LOOP_PROMPT" 2>&1 | sed 's/^/    /'

log "✓ gestartet"
