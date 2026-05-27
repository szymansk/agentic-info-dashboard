#!/usr/bin/env bash
#
# loop.sh — Convenience-Wrapper für die Claude-Background-Session
#           "daily-ai-update" (oder eine andere via -n <name>).
#
# Subcommands:
#   id        Druckt die short-ID der Session
#   status    Zeigt PID, Alter, Worktree
#   log       Holt logs, ANSI-Sequenzen rausgefiltert
#   raw-log   Holt logs ungefiltert (für Debug der TUI-Streams)
#   attach    Attached an die Session (`claude attach`)
#   stop      Stoppt die Session
#   restart   Stoppt und startet neu via start-daily-loop.sh
#
# Beispiele:
#   ./bin/loop.sh log
#   ./bin/loop.sh status
#   ./bin/loop.sh attach
#   ./bin/loop.sh -n some-other-session log
#
set -euo pipefail

NAME="daily-ai-update"
ROSTER="$HOME/.claude/daemon/roster.json"
CLAUDE="$(command -v claude || echo /usr/bin/claude)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Argument-Parsing ───────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--name) NAME="$2"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# *//'; exit 0 ;;
    *) break ;;
  esac
done

CMD="${1:-status}"
shift || true

# ── ID per Name auflösen ───────────────────────────────────────────
resolve_id() {
  if [ ! -f "$ROSTER" ]; then
    echo ""
    return
  fi
  python3 - "$ROSTER" "$NAME" <<'PY'
import json, sys
roster_path, name = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(roster_path))
except Exception:
    sys.exit(0)
raw = data.get('workers', data.get('sessions', [])) if isinstance(data, dict) else data
entries = list(raw.values()) if isinstance(raw, dict) else (raw or [])
for e in entries:
    if not isinstance(e, dict): continue
    entry_name = e.get('name') or e.get('dispatch', {}).get('seed', {}).get('name')
    if entry_name == name:
        sid = e.get('sessionId', '')
        # short-id = erste 8 Zeichen ist die Konvention
        print(sid.split('-')[0] if sid else '')
        break
PY
}

# ── Session-Metadaten ──────────────────────────────────────────────
get_meta() {
  python3 - "$ROSTER" "$NAME" <<'PY'
import json, os, sys, time
roster_path, name = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(roster_path))
except Exception:
    sys.exit(0)
raw = data.get('workers', data.get('sessions', [])) if isinstance(data, dict) else data
entries = list(raw.values()) if isinstance(raw, dict) else (raw or [])
for e in entries:
    if not isinstance(e, dict): continue
    entry_name = e.get('name') or e.get('dispatch', {}).get('seed', {}).get('name')
    if entry_name != name: continue
    pid = e.get('pid')
    alive = '?'
    if pid:
        try: os.kill(pid, 0); alive = 'alive'
        except: alive = 'dead'
    started = e.get('startedAt')
    age = ''
    if started:
        s = (time.time() * 1000 - started) / 1000
        h = int(s // 3600); m = int((s % 3600) // 60)
        age = f"{h}h{m:02d}m"
    sid_full = e.get('sessionId', '')
    short = sid_full.split('-')[0] if sid_full else ''
    print(f"name      : {entry_name}")
    print(f"short-id  : {short}")
    print(f"session-id: {sid_full}")
    print(f"pid       : {pid} ({alive})")
    print(f"started   : {age} ago")
    print(f"cwd       : {e.get('cwd', '?')}")
    print(f"attempt   : {e.get('attempt', '?')}")
    print(f"cli       : v{e.get('cliVersion', '?')}")
    break
else:
    print(f"(keine Session mit Namen '{name}' im Roster)")
PY
}

# ── Subcommand-Dispatch ────────────────────────────────────────────
case "$CMD" in
  id)
    id=$(resolve_id)
    [ -z "$id" ] && { echo "(no session named '$NAME')" >&2; exit 1; }
    echo "$id"
    ;;

  status)
    get_meta
    ;;

  log)
    id=$(resolve_id)
    [ -z "$id" ] && { echo "(no session named '$NAME')" >&2; exit 1; }
    # ANSI-Escape-Sequenzen entfernen + Carriage-Returns + redundante Whitespace
    "$CLAUDE" logs "$id" 2>&1 | \
      python3 -c "
import sys, re
ansi = re.compile(r'\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07]*\x07|\x1b[=>NOPQRZc78=>]')
text = sys.stdin.buffer.read().decode('utf-8', errors='replace')
text = ansi.sub('', text)
text = text.replace('\r', '\n')
# Mehrere Leerzeilen auf eine kürzen
text = re.sub(r'\n\s*\n+', '\n\n', text)
sys.stdout.write(text)
"
    ;;

  raw-log)
    id=$(resolve_id)
    [ -z "$id" ] && { echo "(no session named '$NAME')" >&2; exit 1; }
    "$CLAUDE" logs "$id"
    ;;

  attach)
    id=$(resolve_id)
    [ -z "$id" ] && { echo "(no session named '$NAME')" >&2; exit 1; }
    echo "Attaching to $NAME ($id) — press ← to detach, Ctrl+Z für sofortiges detach"
    sleep 1
    exec "$CLAUDE" attach "$id"
    ;;

  stop)
    id=$(resolve_id)
    [ -z "$id" ] && { echo "(no session named '$NAME')" >&2; exit 1; }
    echo "Stopping $NAME ($id) …"
    "$CLAUDE" stop "$id"
    ;;

  restart)
    id=$(resolve_id)
    if [ -n "$id" ]; then
      echo "Stopping existing $NAME ($id) …"
      "$CLAUDE" stop "$id" || true
      sleep 1
    fi
    echo "Starting fresh session …"
    exec "$SCRIPT_DIR/start-daily-loop.sh"
    ;;

  *)
    echo "Unbekanntes Subcommand: $CMD" >&2
    sed -n '2,18p' "$0" | sed 's/^# *//' >&2
    exit 2
    ;;
esac
