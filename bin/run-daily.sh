#!/usr/bin/env bash
#
# run-daily.sh — der Tageslauf des ai-news-dashboards (Spec 5.2).
# Von systemd (ai-news-dashboard-daily.service) oder von Hand: `bin/run-daily.sh </dev/null`.
#
#   --dry-run          Preflight + Entscheidung, kein Lauf, kein State
#   --reset-attempts   Tageszähler löschen (nach Tests)
#   DAILY_ENV=<pfad>   andere daily.env (Fehlerinjektion)
#
# Exit: 0 ok · 3 AUTH · 4 DIRTY · 5 RUN · 6 OUTCOME · 7 BLOCKED · 8 API · 9 REPO
#       · 10 QUALITY · 11 GIVEUP (dritter wiederholbarer Fehlschlag des Tages)
#
set -uo pipefail
LOG_TAG=daily
# shellcheck source=bin/lib-daily.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-daily.sh"
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT_FILE="$PROJECT_DIR/DAILY_UPDATE.md"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
LOCK_WAIT_SEC="${LOCK_WAIT_SEC:-300}"

DRY=0
case "${1:-}" in
  --dry-run) DRY=1 ;;
  --reset-attempts) rm -f "$STATE_DIR"/attempts.*; log "Tageszähler gelöscht"; exit 0 ;;
  "") ;;
  *) echo "usage: run-daily.sh [--dry-run|--reset-attempts]" >&2; exit 64 ;;
esac

RUN_DATE="$(today)"
START_TS="$(date +%s)"
HEAD0=""
CLAUDE_BIN="${CLAUDE_BIN:-}"  # evtl. schon von außen gesetzter Override bleibt für resolve_claude() erhalten
attempts="$(state_read "attempts.$RUN_DATE")"; attempts="${attempts:-0}"

ping_hc() {  # ping_hc start|fail|"" — nur wenn HEALTHCHECKS_URL gesetzt
  [ -n "${HEALTHCHECKS_URL:-}" ] || return 0
  curl -fsS -m 10 "$HEALTHCHECKS_URL${1:+/$1}" >/dev/null 2>&1 9>&- || true
}

existing_own_paths() {  # füllt EXISTING_OWN_PATHS mit den OWN_DIRT_PATHS-
  # Einträgen, zu denen `git status` etwas zu sagen hat — NICHT `[ -e ]`:
  # das schlösse eine komplett gelöschte Datei aus (Verzeichnis existiert
  # dann nicht mehr, die Löschung müsste aber gestasht werden) und schlösse
  # leere/unveränderte Verzeichnisse ein, an denen `git stash push --
  # <pfade>` sonst mit "pathspec did not match" fatal scheitert (Spec 5.2).
  EXISTING_OWN_PATHS=()
  local p
  for p in "${OWN_DIRT_PATHS[@]}"; do
    [ -n "$(git status --porcelain --untracked-files=all -- "$p" 2>/dev/null)" ] && EXISTING_OWN_PATHS+=("$p")
  done
}

write_last_run() {  # <exit> <ART> <text>
  python3 - "$STATE_DIR/last-run.json" "$1" "$2" "$3" "$RUN_DATE" "$START_TS" \
            "$STATE_DIR/last-run.out.json" "$("$CLAUDE_BIN" --version 2>/dev/null | head -1 || true)" <<'PY'
import json, os, sys, time
p, code, kind, text, run_date, start, outf, ver = sys.argv[1:9]
d = {"date": run_date, "finished": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
     "duration_s": int(time.time()) - int(start), "exit": int(code), "kind": kind,
     "text": text, "claude_version": ver}
try:
    if os.path.getmtime(outf) >= int(start):
        o = json.load(open(outf))
        d.update({k: o.get(k) for k in ("total_cost_usd", "num_turns", "session_id", "terminal_reason")})
        st = [l for l in (o.get("result") or "").splitlines() if l.startswith("STATUS:")]
        if st: d["status"] = st[-1]
except Exception:
    pass
json.dump(d, open(p, "w"), ensure_ascii=False, indent=1)
PY
}

cleanup_leftovers() {  # <exit> — nur, wenn der Lauf noch nichts committet hat
  [ -n "$HEAD0" ] || return 0
  if [ "$(git rev-parse HEAD 2>/dev/null)" != "$HEAD0" ]; then
    log "Lauf hat bereits committet — keine Aufräumung (Timeline bleibt konsistent)"; return 0
  fi
  if [ "$(git status --porcelain --untracked-files=all | classify_dirt)" != clean ]; then
    existing_own_paths
    if [ "${#EXISTING_OWN_PATHS[@]}" -gt 0 ] \
       && git stash push -u -q -m "daily-fail $(date -Is) exit $1" -- "${EXISTING_OWN_PATHS[@]}" 9>&-; then
      log "Reste des Laufs gestasht (git stash list)"
    else
      warn "git stash der Reste fehlgeschlagen — Dirt-Klassifikation räumt beim nächsten Start"
    fi
  fi
  if [ -f "$STATE_DIR/manifest.bak" ]; then
    cp "$STATE_DIR/manifest.bak" dashboards/ai-news/archive/manifest.json && log "manifest.json zurückgesetzt"
  fi
}

fail() {  # fail <code> <ART> <text> — State, Zähler, Cleanup, exit
  local code="$1" kind="$2" text="$3"
  warn "[$kind] $text"
  if [ "$DRY" = 1 ]; then log "[dry-run] würde mit Exit $code ($kind) enden"; exit "$code"; fi
  cleanup_leftovers "$code"
  case "$code" in
    5|6|7)
      attempts=$((attempts + 1)); state_write "attempts.$RUN_DATE" "$attempts"
      if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
        printf 'GIVEUP\n%s. Fehlschlag heute (%s): %s\n' "$attempts" "$kind" "$text" > "$STATE_DIR/last-failure.daily"
        write_last_run 11 GIVEUP "$kind: $text"; ping_hc fail; exit 11
      fi ;;
  esac
  printf '%s\n%s\n' "$kind" "$text" > "$STATE_DIR/last-failure.daily"
  write_last_run "$code" "$kind" "$text"
  case "$code" in 3|4|8|9|10) ping_hc fail ;; esac
  exit "$code"
}

on_term() {
  trap - TERM INT
  fail 5 TIMEOUT "Lauf abgebrochen (TimeoutStartSec oder Signal) nach $(( $(date +%s) - START_TS )) s"
}
trap on_term TERM INT

poll_pages() {  # bis 10 min auf das neue Datum warten; nur Warnung
  local i d=""
  for i in 1 2 3 4 5 6 7 8 9 10; do
    d="$(curl -fsS -m 15 -H 'Cache-Control: no-cache' "$PAGES_URL" 2>/dev/null 9>&- \
          | grep -oE 'data-snapshot-date="[0-9-]{10}"' | head -1 | grep -oE '[0-9-]{10}' || true)"
    if [ -n "$d" ] && [[ ! "$d" < "$RUN_DATE" ]]; then log "Pages zeigt $d"; return 0; fi
    [ "$i" -lt 10 ] && sleep 60
  done
  warn "Pages zeigt nach 10 min noch ${d:-nichts} — der Watchdog meldet PUBLIC_STALE, falls es so bleibt"
}

verify_and_finish() {
  local vout vrc=0 reason prev="" status
  # prev-snapshot nur verwenden, wenn DIESER Lauf es geschrieben hat (Schritt
  # 6) — im push-only-Pfad (kein Schritt 6) wäre die Datei ein Rest eines
  # früheren Laufs; verify-briefing.sh ermittelt PREV dann selbst aus der
  # Historie statt mit einem veralteten Datum zu scheitern.
  if [ -f "$STATE_DIR/prev-snapshot" ] && [ "$(stat -c %Y "$STATE_DIR/prev-snapshot")" -ge "$START_TS" ]; then
    prev="$(state_read prev-snapshot)"
  fi
  vout="$("$BIN/verify-briefing.sh" --full --date "$RUN_DATE" ${prev:+--prev "$prev"} 2>&1)" || vrc=$?
  printf '%s\n' "$vout" | sed 's/^/    /'
  reason="$(printf '%s\n' "$vout" | grep '^RESULT:' | tail -1)"; reason="${reason#RESULT: }"
  case "$vrc" in
    0) ;;
    6) fail 6 OUTCOME "$reason" ;;
    *) fail 10 QUALITY "$reason" ;;
  esac
  status=""
  if [ -f "$STATE_DIR/last-run.out.json" ] && [ "$(stat -c %Y "$STATE_DIR/last-run.out.json")" -ge "$START_TS" ]; then
    status="$(python3 -c 'import json,sys
r=(json.load(open(sys.argv[1])).get("result") or "")
l=[x for x in r.splitlines() if x.startswith("STATUS:")]
print(l[-1] if l else "")' "$STATE_DIR/last-run.out.json" 2>/dev/null || true)"
  fi
  log "${status:-STATUS: (keine Bilanz-Zeile im Ergebnis)}"
  write_last_run 0 OK "${status:-ok}"
  rm -f "$STATE_DIR/attempts.$RUN_DATE" "$STATE_DIR/last-failure.daily" "$STATE_DIR/last-alert"
  ping_hc ""
  trap - TERM INT  # Erfolg ist verbucht — ein spätes Signal darf last-run.json/attempts nicht mehr zu fail() umbiegen
  poll_pages
  return 0
}

push_only() {
  local out
  if out="$(git push origin main 2>&1 9>&-)"; then
    log "push ok"; verify_and_finish; return 0
  fi
  if grep -qiE "non-fast-forward|rejected|fetch first" <<<"$out"; then
    fail 9 REPO "push abgelehnt (non-fast-forward): ${out:0:120}"
  fi
  fail 6 OUTCOME "push fehlgeschlagen: ${out:0:120}"
}

main() {
  local env_rc dirt fetch_out cur ahead rc cls code kind text prompt
  local out="$STATE_DIR/last-run.out.json"

  # 0. Binary + Env
  CLAUDE_BIN="$(resolve_claude)" || fail 5 RUN "claude-Binary nicht gefunden (~/.local/bin/claude?)"
  load_env "$DAILY_ENV"; env_rc=$?
  [ "$env_rc" = 2 ] && fail 3 AUTH "daily.env ungültig ($DAILY_ENV): Format KEY=wert, keine Inline-Kommentare"
  load_env "$ALERT_ENV" || true
  [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || fail 3 AUTH "CLAUDE_CODE_OAUTH_TOKEN fehlt in $DAILY_ENV — 'claude setup-token' und bin/set-token.sh"
  CLAUDE_MODEL="${CLAUDE_MODEL:-claude-opus-4-8}"; MAX_BUDGET_USD="${MAX_BUDGET_USD:-30}"
  cd "$PROJECT_DIR" || fail 5 RUN "PROJECT_DIR fehlt: $PROJECT_DIR"
  [ -f "$PROMPT_FILE" ] || fail 5 RUN "DAILY_UPDATE.md fehlt"

  # 0b. Übergangs-Warnung (Migration Phase 2): alte Background-Session könnte noch laufen
  roster="$HOME/.claude/daemon/roster.json"
  if [ -f "$roster" ]; then
    old_pid="$(python3 - "$roster" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = None
items = None
if isinstance(d, list):
    items = d
elif isinstance(d, dict):
    items = d.get("workers")
    if items is None: items = d.get("sessions")
    if items is None: items = list(d.values())
# "workers"/"sessions" ist in der echten roster.json ein dict, keyed by ID
# (Fix F1) — nicht nur die Top-Ebene kann ein dict sein.
if isinstance(items, dict): items = list(items.values())
if not isinstance(items, list): items = []
for w in items:
    if not isinstance(w, dict): continue
    name = w.get("name") or ((w.get("dispatch") or {}).get("seed") or {}).get("name")
    if name == "daily-ai-update":
        pid = w.get("pid") or (w.get("dispatch") or {}).get("pid")
        if pid: print(pid)
        break
PY
)"
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
      warn "alte Background-Session 'daily-ai-update' läuft noch (pid $old_pid) — vor dem ersten Timer-Lauf stoppen: ./bin/loop.sh stop"
    fi
  fi

  # 1. Lock (paralleler Handlauf ist kein Alarm); --dry-run wartet nicht darauf
  #    (Spec 5.2/Invariante: ein reiner Preflight-Check darf nie 5 min blockieren)
  exec 9>"$STATE_DIR/run.lock"
  if [ "$DRY" = 1 ]; then
    if ! flock -n 9; then
      log "Lauf aktiv (Lock gehalten) — dry-run beendet"; exit 0
    fi
  elif ! flock -w "$LOCK_WAIT_SEC" 9; then
    log "anderer Lauf hält das Lock seit > $LOCK_WAIT_SEC s — beende ohne Alarm"; exit 0
  fi

  # 2. Zähler
  log "Lauf $RUN_DATE — bisherige Fehlschläge heute: $attempts (Abbruch ab $MAX_ATTEMPTS)"

  # 3. Dirt
  dirt="$(git status --porcelain --untracked-files=all | classify_dirt)"
  case "$dirt" in
    foreign) fail 4 DIRTY "fremde Änderungen im Working Tree: $(git status --porcelain --untracked-files=all | head -5 | tr '\n' ';') — committen oder stashen" ;;
    own)
      warn "Reste eines früheren Laufs/Deploys im Tree"
      if [ "$DRY" = 1 ]; then
        log "[dry-run] würde die Reste stashen"
      else
        existing_own_paths
        [ "${#EXISTING_OWN_PATHS[@]}" -gt 0 ] || fail 5 RUN "own-Dirt erkannt, aber keiner der OWN_DIRT_PATHS existiert auf der Platte"
        git stash push -u -q -m "daily-leftover $(date -Is)" -- "${EXISTING_OWN_PATHS[@]}" 9>&- || fail 5 RUN "git stash der Reste fehlgeschlagen"
      fi ;;
  esac

  # 4. Repo (nach dem Stash, sonst liefe der Lauf auf veralteter Basis)
  if [ -f .git/index.lock ] && [ $(( $(date +%s) - $(stat -c %Y .git/index.lock) )) -gt 3600 ]; then
    rm -f .git/index.lock; warn "verwaistes .git/index.lock entfernt"
  fi
  if ! fetch_out="$(git fetch origin 2>&1 9>&-)"; then
    if grep -qiE "authentication failed|could not read username|403" <<<"$fetch_out"; then
      fail 9 REPO "GitHub-Auth beim Fetch fehlgeschlagen — 'gh auth status' prüfen"
    fi
    fail 5 RUN "git fetch fehlgeschlagen: ${fetch_out:0:120}"
  fi
  if [ "$DRY" != 1 ]; then
    git merge --ff-only -q origin/main 2>/dev/null 9>&- || fail 9 REPO "lokal und origin/main divergieren — von Hand rebasen"
  fi

  # 5. Idempotenz / push-only
  cur="$(snapshot_date dashboards/ai-news/index.html)"
  ahead="$(git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)"
  if [ "$cur" = "$RUN_DATE" ] && [ "$(git status --porcelain --untracked-files=all | classify_dirt)" = clean ]; then
    if [ "$ahead" = 0 ]; then
      log "Briefing vom $RUN_DATE ist gepusht — nichts zu tun"
      # --dry-run (u.a. von check.sh bei jedem Aufruf) darf last-alert/
      # last-failure.daily nicht als Nebeneffekt eines reinen Preflight-Checks
      # löschen und keinen State schreiben. Der echte Lauf verifiziert auch im
      # "nichts zu tun"-Fall (z.B. korrumpiertes Manifest eines Vortages) statt
      # blind Exit 0 zu melden, und räumt/protokolliert wie jeder Erfolg.
      [ "$DRY" = 1 ] && exit 0
      verify_and_finish
      exit 0
    fi
    log "Briefing vom $RUN_DATE committet, $ahead Commit(s) nicht gepusht → push-only"
    [ "$DRY" = 1 ] && { log "[dry-run] würde nur pushen"; exit 0; }
    push_only; exit 0
  fi
  if [ "$DRY" = 1 ]; then
    log "[dry-run] würde claude -p starten (model=$CLAUDE_MODEL, budget=$MAX_BUDGET_USD USD; Briefing aktuell vom ${cur:-?})"; exit 0
  fi

  # 6. Sicherung
  HEAD0="$(git rev-parse HEAD)"
  cp dashboards/ai-news/archive/manifest.json "$STATE_DIR/manifest.bak" 2>/dev/null || true
  state_write prev-snapshot "$cur"
  ping_hc start

  # 7. Lauf
  prompt="Du läufst unbeaufsichtigt als Oneshot ohne Rückfragemöglichkeit. Lies $PROMPT_FILE und führe den dort beschriebenen Daily-Update-Workflow für das ai-news-dashboard vollständig aus. Working directory ist $PROJECT_DIR. Wenn etwas endgültig blockiert, gib als letzte Zeile 'BLOCKED: <Grund>' aus und höre auf."
  log "starte claude -p (model=$CLAUDE_MODEL, budget=$MAX_BUDGET_USD USD)"
  rc=0
  "$CLAUDE_BIN" -p --output-format json --model "$CLAUDE_MODEL" \
      ${FALLBACK_MODEL:+--fallback-model "$FALLBACK_MODEL"} \
      ${CLAUDE_SETTING_SOURCES:+--setting-sources "$CLAUDE_SETTING_SOURCES"} \
      --dangerously-skip-permissions --strict-mcp-config --disallowedTools AskUserQuestion \
      --max-budget-usd "$MAX_BUDGET_USD" "$prompt" >"$out" </dev/null 9>&- || rc=$?
  log "claude -p beendet mit rc=$rc nach $(( $(date +%s) - START_TS )) s"

  # 8. Klassifikation
  cls="$(classify_result "$out")"
  [ -n "$cls" ] || cls="5 RUN Klassifikation lieferte nichts"
  code="${cls%% *}"; kind="$(cut -d' ' -f2 <<<"$cls")"; text="$(cut -d' ' -f3- <<<"$cls")"
  [ "$code" = 0 ] || fail "$code" "$kind" "$text"
  grep -q '"permission_denials": *\[[^]]' "$out" 2>/dev/null && warn "permission_denials nicht leer — der Lauf konnte nicht alles ausführen"

  # 9./10. Ergebnis, State, Pages
  verify_and_finish
  exit 0
}

main
