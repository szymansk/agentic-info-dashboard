# Tageslauf als systemd-Oneshot — Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Den täglichen Briefing-Lauf von der Background-Session (`claude --bg` + `/loop 24h`) auf systemd-Timer → Oneshot → `claude -p` umstellen, mit Retry, WhatsApp-Alarm, Ergebnisprüfung und externem Wächter.

**Architecture:** Ein Timer startet täglich 07:15 `bin/run-daily.sh`, das `claude -p` mit `DAILY_UPDATE.md` ausführt, das JSON-Ergebnis klassifiziert, das Briefing prüft und Reste bei Fehlern wegräumt. systemd wiederholt wiederholbare Fehler alle 2 h; nicht-wiederholbare und der dritte Fehlschlag des Tages lösen sofort `OnFailure` → `bin/alert.sh` → CallMeBot aus. `bin/watchdog.sh` prüft alle 30 min das Ergebnis (Briefing-Alter lokal und auf Pages, Token, YouTube) und ein GitHub-Actions-Workflow prüft das Pages-Datum von außen.

**Tech Stack:** bash 5 (`set -uo pipefail`), python3 (stdlib, eingebettet für JSON/HTML), systemd 259 (Fedora 44, SELinux Enforcing), Claude Code CLI ≥ 2.1.281 (`claude -p --output-format json`), curl, gh, git, GitHub Actions.

**Spec:** `specs/2026-09-24-daily-run-oneshot-design.md` (Version 2.1). Der Plan argumentiert aus der Spec; Ausführende lesen beides.

## Global Constraints

- Sprache: Kommentare, Log- und Alarmtexte deutsch; Skriptnamen englisch (bestehende Konvention).
- Alle Skripte unter `bin/` beginnen mit `#!/usr/bin/env bash` und `set -uo pipefail` (**kein** `set -e`: Exit-Codes werden explizit behandelt). Shellcheck ist nicht installiert; `bash -n` ist Pflicht vor jedem Commit.
- Env-Dateien `~/.config/ai-news-dashboard/daily.env` und `alert.env`: Format `KEY=wert`, keine Leerzeichen um `=`, Kommentare nur als ganze Zeilen, keine `$`-Expansion, Rechte 600, nie im Repo. Laden immer über `load_env` aus `bin/lib-daily.sh` (`set -a` … `set +a`).
- Secrets nie loggen: kein `set -x`, kein `curl -v`, Token nie als Argument übergeben (nur stdin oder Env).
- Exit-Codes von `run-daily.sh` exakt wie Spec 5.2: 0 ok · 3 AUTH · 4 DIRTY · 5 RUN · 6 OUTCOME · 7 BLOCKED · 8 API · 9 REPO · 10 QUALITY · 11 GIVEUP. `RestartPreventExitStatus=3 4 8 9 10 11`.
- Eigener Dirt = Pfade unter `dashboards/ai-news/`, `dashboards/it-services/`, `docs/`. Alles andere ist fremd. `dashboards/youtube/data.json`, `dashboards/ai-news/archive/*.html`, `archive/manifest.json` sind gitignored (Voraussetzung der Dirt-Logik).
- State-Verzeichnis `~/.local/state/ai-news-dashboard/` (`$STATE_DIR`), Konfig `~/.config/ai-news-dashboard/` (`$CONF_DIR`).
- Alle systemd-Exec-Zeilen: `/usr/bin/bash <absoluter Pfad>` mit `WorkingDirectory=$PROJECT_DIR`.
- `docs/` ist Pages-Build-Output (wird von `scripts/build-pages.py` gelöscht und neu erzeugt): nie von Hand editieren, nichts darunter ablegen.
- Modell-Pin `claude-opus-4-8` (am 24.09. verifiziert), überschreibbar per `CLAUDE_MODEL` in `daily.env`.
- Commits: eigene, kleine Commits pro Task mit der Attribution `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Während die alte Background-Session noch läuft (bis Phase 2), nach jedem Task committen, sonst sammelt ihr Deploy die Änderungen ein.
- Nichts mit `sudo` in den Build-Tasks (Tasks 1–13). sudo nur in der Migration (Task 14) durch Marc.

---

## Dateistruktur

| Datei | Verantwortung | Task |
|---|---|---|
| `bin/lib-daily.sh` | gemeinsame Helfer: Pfade, Env laden/validieren, Logging, claude-Binary, Snapshot-Datum, Datumsrechnung | 1 |
| `bin/alert.sh` | einziger Alarm-Versandweg (Journal, Statusdateien, CallMeBot, ntfy, pending) | 2 |
| `bin/verify-briefing.sh` | Ergebnisprüfung `--pre-deploy` / `--full` | 3 |
| `bin/run-daily.sh` | der Tageslauf (Preflight, `claude -p`, Klassifikation, Verify, Cleanup, State) | 4, 5 |
| `bin/watchdog.sh` | 30-min-Prüfungen und Alarme | 6 |
| `bin/set-token.sh` | schreibt Token + `TOKEN_CREATED` nach `daily.env` | 7 |
| `DAILY_UPDATE.md` | Betriebsmodus unbeaufsichtigt, Idempotenz, `STATUS:`-Marker | 8 |
| `bin/deploy.sh` | `git add` mit Pathspec, `restorecon -R bin/` | 9 |
| `install.sh`, `bin/verify-daily.sh` | Unit-Vorlagen, Reihenfolge, Env-Prüfung; systemd-Live-Test | 10 |
| `.github/workflows/stale-check.yml` | externer Wächter | 11 |
| `bin/check.sh` | Sektion „daily run" | 12 |
| `CLAUDE.md`, Memory | Runbook, Historie | 13 |
| `tests/test-*.sh`, `tests/fixtures/` | Bash-Tests ohne Netz und ohne Token | 1–6 |

Testkonvention: jedes `tests/test-<name>.sh` ist eigenständig ausführbar, nutzt die
Helfer aus `tests/lib-test.sh` (`assert_eq`, `assert_rc`, `assert_contains`), legt
temporäre Verzeichnisse unter `$(mktemp -d)` an und setzt `STATE_DIR`, `CONF_DIR`,
`PROJECT_DIR` per Env um. `tests/run-all.sh` führt alle aus. Kein Test ruft `claude`,
`curl`, `systemctl` oder `gh` real auf (Stubs per `PATH`-Voranstellung).

---

### Task 1: Test-Helfer und `bin/lib-daily.sh`

**Files:**
- Create: `tests/lib-test.sh`
- Create: `tests/run-all.sh`
- Create: `bin/lib-daily.sh`
- Test: `tests/test-lib.sh`

**Interfaces:**
- Produces (für alle späteren Tasks, durch `. "$(dirname "${BASH_SOURCE[0]}")/lib-daily.sh"` geladen):
  - Variablen `PROJECT_DIR`, `STATE_DIR`, `CONF_DIR`, `DAILY_ENV`, `ALERT_ENV`, `PAGES_URL`, `LOG_TAG`
  - `log "<text>"`, `warn "<text>"` (stderr)
  - `env_file_valid <datei>` → rc 0/1
  - `load_env <datei>` → rc 0 geladen, 1 fehlt, 2 ungültig (lädt mit `set -a`)
  - `resolve_claude` → druckt Pfad, rc 1 wenn keiner
  - `snapshot_date <html>` → `YYYY-MM-DD` oder leer
  - `days_between <früher> <später>` → ganze Tage
  - `today` → `date -I`
  - `state_write <name> <inhalt>` / `state_read <name>` (Dateien in `$STATE_DIR`)

- [ ] **Step 1: Test-Helfer anlegen**

`tests/lib-test.sh`:

```bash
# shellcheck shell=bash
# Mini-Testhelfer. Sourcen, dann assert_* nutzen. Am Ende: test_summary.
_T_PASS=0; _T_FAIL=0
assert_eq() {   # assert_eq <erwartet> <ist> [<name>]
  if [ "$1" = "$2" ]; then _T_PASS=$((_T_PASS+1)); printf '  ok   %s\n' "${3:-assert_eq}"
  else _T_FAIL=$((_T_FAIL+1)); printf '  FAIL %s\n       erwartet: %q\n       ist:      %q\n' "${3:-assert_eq}" "$1" "$2"; fi
}
assert_rc() {   # assert_rc <erwartet> <name> -- <kommando…>
  local want="$1" name="$2"; shift 3
  local rc=0; "$@" >/dev/null 2>&1 || rc=$?
  assert_eq "$want" "$rc" "$name (rc)"
}
assert_contains() {  # assert_contains <needle> <haystack> [<name>]
  if [[ "$2" == *"$1"* ]]; then _T_PASS=$((_T_PASS+1)); printf '  ok   %s\n' "${3:-assert_contains}"
  else _T_FAIL=$((_T_FAIL+1)); printf '  FAIL %s\n       fehlt: %q\n       in:    %q\n' "${3:-assert_contains}" "$1" "$2"; fi
}
test_summary() {
  printf '%s: %d ok, %d fehlgeschlagen\n' "$(basename "$0")" "$_T_PASS" "$_T_FAIL"
  [ "$_T_FAIL" -eq 0 ]
}
# Sandbox: eigenes STATE_DIR/CONF_DIR pro Test, Stub-PATH für claude/curl/systemctl/gh
test_sandbox() {
  export T_ROOT; T_ROOT="$(mktemp -d)"
  export STATE_DIR="$T_ROOT/state" CONF_DIR="$T_ROOT/conf" STUB_BIN="$T_ROOT/bin"
  mkdir -p "$STATE_DIR" "$CONF_DIR" "$STUB_BIN"
  export PATH="$STUB_BIN:$PATH"
  trap 'rm -rf "$T_ROOT"' EXIT
}
stub() {   # stub <name> <bash-body>   → ausführbarer Stub in $STUB_BIN
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$STUB_BIN/$1"; chmod +x "$STUB_BIN/$1"
}
```

`tests/run-all.sh`:

```bash
#!/usr/bin/env bash
# Führt alle tests/test-*.sh aus; Exit ≠ 0, wenn einer scheitert.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
fail=0
for t in tests/test-*.sh; do
  echo "== $t"; bash "$t" || fail=1
done
[ "$fail" -eq 0 ] && echo "ALLE TESTS OK" || { echo "TESTS FEHLGESCHLAGEN"; exit 1; }
```

- [ ] **Step 2: Fehlschlagenden Test für lib-daily.sh schreiben**

`tests/test-lib.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
. tests/lib-test.sh; test_sandbox
. bin/lib-daily.sh

# env_file_valid
printf 'A=1\n# Kommentar\nB=x-y_z\n\n' > "$T_ROOT/ok.env"
assert_rc 0 "env gültig" -- env_file_valid "$T_ROOT/ok.env"
printf 'A=1 # inline\n' > "$T_ROOT/bad1.env"
assert_rc 1 "inline-Kommentar ungültig" -- env_file_valid "$T_ROOT/bad1.env"
printf 'A = 1\n' > "$T_ROOT/bad2.env"
assert_rc 1 "Leerzeichen um = ungültig" -- env_file_valid "$T_ROOT/bad2.env"
printf 'export A=1\n' > "$T_ROOT/bad3.env"
assert_rc 1 "export ungültig" -- env_file_valid "$T_ROOT/bad3.env"

# load_env
assert_rc 1 "load_env fehlend" -- load_env "$T_ROOT/nein.env"
assert_rc 2 "load_env ungültig" -- load_env "$T_ROOT/bad1.env"
load_env "$T_ROOT/ok.env"; assert_eq "x-y_z" "${B:-}" "load_env exportiert B"
assert_eq "x-y_z" "$(bash -c 'echo "$B"')" "B ist exportiert (Kindprozess)"

# snapshot_date
printf '<body data-snapshot-date="2026-09-24" data-snapshot-mode="live">' > "$T_ROOT/a.html"
assert_eq "2026-09-24" "$(snapshot_date "$T_ROOT/a.html")" "snapshot_date"
assert_eq "" "$(snapshot_date "$T_ROOT/fehlt.html")" "snapshot_date fehlend → leer"

# days_between
assert_eq "2" "$(days_between 2026-09-22 2026-09-24)" "days_between"
assert_eq "0" "$(days_between 2026-09-24 2026-09-24)" "days_between gleich"

# state
state_write foo "hallo"; assert_eq "hallo" "$(state_read foo)" "state roundtrip"
assert_eq "" "$(state_read gibtsnicht)" "state_read fehlend → leer"

# resolve_claude mit Stub
stub claude 'echo stub'; assert_eq "$STUB_BIN/claude" "$(HOME=/nonexistent resolve_claude)" "resolve_claude via PATH"
test_summary
```

- [ ] **Step 3: Test laufen lassen, Fehlschlag sehen**

Run: `bash tests/test-lib.sh`
Expected: bricht ab mit `bin/lib-daily.sh: No such file or directory`.

- [ ] **Step 4: `bin/lib-daily.sh` schreiben**

```bash
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
```

- [ ] **Step 5: Tests laufen lassen**

Run: `bash -n bin/lib-daily.sh && bash tests/test-lib.sh && bash tests/run-all.sh`
Expected: alle `ok`, Zeile `test-lib.sh: 15 ok, 0 fehlgeschlagen`, `ALLE TESTS OK`.

- [ ] **Step 6: Commit**

```bash
git add bin/lib-daily.sh tests/lib-test.sh tests/run-all.sh tests/test-lib.sh
git commit -m "daily: gemeinsame Helfer-Bibliothek + Test-Gerüst

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: `bin/alert.sh`

**Files:**
- Create: `bin/alert.sh`
- Test: `tests/test-alert.sh`

**Interfaces:**
- Consumes: `bin/lib-daily.sh` (`load_env`, `STATE_DIR`, `ALERT_ENV`, `log`, `warn`, `snapshot_date`)
- Produces:
  - CLI: `alert.sh <ART> <Text…>` · `alert.sh unit-failed <unit-präfix>` · `alert.sh --resend` · `alert.sh --test` · Optionen `--force`, `--dry-run`
  - Dateien in `$STATE_DIR`: `alerts.log` (TSV: Zeit, ART, Text), `last-alert` (3 Zeilen: ART, Zeit, Text), `sent.<kanal>.<hash>` (Drossel-Stempel), `pending/<hash>` + `pending/<hash>.tries`
  - liest `$STATE_DIR/last-failure.<kurzname>` (Zeile 1 = ART, Rest = Text), geschrieben von `run-daily.sh`/`watchdog.sh`
  - Env aus `alert.env`: `CALLMEBOT_PHONE`, `CALLMEBOT_APIKEY`, `NTFY_TOPIC`/`NTFY_URL`; Testhaken `ALERT_CURL` (Pfad zu einem curl-Ersatz)
  - Exit 0 = zugestellt oder gedrosselt; 1 = pending; 64 = Usage

- [ ] **Step 1: Fehlschlagenden Test schreiben**

`tests/test-alert.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
. tests/lib-test.sh; test_sandbox
export ALERT_ENV="$CONF_DIR/alert.env"
printf 'CALLMEBOT_PHONE=491234\nCALLMEBOT_APIKEY=key\n' > "$ALERT_ENV"
stub logger 'exit 0'
# curl-Stub: protokolliert Aufrufe, antwortet je nach CURL_MODE
stub curl 'echo "$@" >> "$STUB_BIN/curl.log"
case "${CURL_MODE:-ok}" in
  ok)   echo "Message queued. You will receive it in a few seconds." ;;
  down) exit 7 ;;
  soft) echo "Error: APIKEY invalid" ;;
esac'
export ALERT_CURL="$STUB_BIN/curl"

# 1. Zustellung ok → Stempel, kein pending, exit 0
assert_rc 0 "alert ok" -- bin/alert.sh TEST "hallo welt"
assert_eq "1" "$(ls "$STATE_DIR"/sent.callmebot.* 2>/dev/null | wc -l)" "Stempel callmebot gesetzt"
assert_eq "0" "$(ls "$STATE_DIR/pending" 2>/dev/null | wc -l)" "kein pending"
assert_contains "text=" "$(cat "$STUB_BIN/curl.log")" "curl mit text"
assert_contains "TEST" "$(sed -n 1p "$STATE_DIR/last-alert")" "last-alert ART"

# 2. gleicher Vorfall erneut → gedrosselt, kein zweiter curl
: > "$STUB_BIN/curl.log"
assert_rc 0 "gedrosselt" -- bin/alert.sh TEST "hallo welt"
assert_eq "" "$(cat "$STUB_BIN/curl.log")" "kein curl bei Drosselung"

# 3. --force → sendet trotzdem
bin/alert.sh --force TEST "hallo welt" >/dev/null 2>&1
assert_contains "text=" "$(cat "$STUB_BIN/curl.log")" "--force sendet"

# 4. curl down → pending, exit 1, kein Stempel für neuen Vorfall
CURL_MODE=down bin/alert.sh STALE "briefing alt" >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "down → exit 1"
assert_eq "1" "$(ls "$STATE_DIR/pending" | grep -vc tries)" "pending angelegt"
assert_eq "0" "$(ls "$STATE_DIR"/sent.callmebot.* | grep -c "$(ls "$STATE_DIR/pending" | grep -v tries)")" "kein Stempel bei down"

# 5. soft-Fehler (200, aber nicht queued) → pending
CURL_MODE=soft bin/alert.sh AUTH "token weg" >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "soft → exit 1"

# 6. --resend mit curl ok → pending geleert
: > "$STUB_BIN/curl.log"
assert_rc 0 "resend" -- bin/alert.sh --resend
assert_eq "0" "$(ls "$STATE_DIR/pending" | grep -vc tries)" "pending nach resend leer"
assert_eq "2" "$(grep -c "text=" "$STUB_BIN/curl.log")" "zwei Nachsendungen"

# 7. --resend: nach 6 Versuchen Sammelnachricht + Abbruch
CURL_MODE=down bin/alert.sh YOUTUBE "yt alt" >/dev/null 2>&1
h="$(ls "$STATE_DIR/pending" | grep -v tries)"; echo 6 > "$STATE_DIR/pending/$h.tries"
: > "$STUB_BIN/curl.log"; bin/alert.sh --resend >/dev/null 2>&1
assert_contains "mehrfach nicht zugestellt" "$(cat "$STUB_BIN/curl.log")" "Sammelnachricht"
assert_eq "0" "$(ls "$STATE_DIR/pending" 2>/dev/null | wc -l)" "pending geräumt"

# 8. unit-failed liest last-failure.<kurzname>
printf 'GIVEUP\ndritter Fehlschlag: RUN 529\n' > "$STATE_DIR/last-failure.daily"
: > "$STUB_BIN/curl.log"; bin/alert.sh unit-failed ai-news-dashboard-daily >/dev/null 2>&1
assert_contains "GIVEUP" "$(cat "$STUB_BIN/curl.log")" "unit-failed nutzt ART aus last-failure"
assert_contains "529" "$(cat "$STUB_BIN/curl.log")" "unit-failed nutzt Text"

# 9. fehlende alert.env → nur Journal, exit 0, kein curl
rm "$ALERT_ENV"; : > "$STUB_BIN/curl.log"
assert_rc 0 "ohne env" -- bin/alert.sh TEST "x"
assert_eq "" "$(cat "$STUB_BIN/curl.log")" "kein curl ohne env"

# 10. --dry-run sendet nicht
printf 'CALLMEBOT_PHONE=491234\nCALLMEBOT_APIKEY=key\n' > "$ALERT_ENV"
: > "$STUB_BIN/curl.log"; bin/alert.sh --dry-run TEST "dry" >/dev/null 2>&1
assert_eq "" "$(cat "$STUB_BIN/curl.log")" "dry-run ohne curl"
assert_rc 64 "usage" -- bin/alert.sh
test_summary
```

- [ ] **Step 2: Test laufen lassen, Fehlschlag sehen**

Run: `bash tests/test-alert.sh`
Expected: viele `FAIL`, weil `bin/alert.sh` fehlt (rc 127).

- [ ] **Step 3: `bin/alert.sh` schreiben**

```bash
#!/usr/bin/env bash
#
# alert.sh — einziger Alarm-Versandweg des ai-news-dashboards (Spec 5.4).
#
#   alert.sh <ART> <Text…>         Alarm auslösen (ART z.B. AUTH, STALE, GIVEUP)
#   alert.sh unit-failed <präfix>  von systemd OnFailure; liest last-failure.<kurz>
#   alert.sh --resend              pending-Alarme nachsenden (Watchdog, alle 30 min)
#   alert.sh --test                Testnachricht
#   Optionen: --force (Drosselung aus), --dry-run (nichts senden)
#
# Reihenfolge: Journal → Statusdateien → Kanäle (CallMeBot, ntfy). Der Drossel-
# Stempel eines Kanals wird nur bei dessen Erfolg gesetzt; sonst pending.
# Exit: 0 zugestellt/gedrosselt · 1 pending · 64 Usage
#
set -uo pipefail
LOG_TAG=alert
# shellcheck source=bin/lib-daily.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-daily.sh"

ALERT_REPEAT_SEC="${ALERT_REPEAT_SEC:-43200}"   # 12 h pro Vorfall und Kanal
MAX_RESEND="${MAX_RESEND:-6}"
CURL="${ALERT_CURL:-curl}"

FORCE=0; DRY=0; args=()
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    --dry-run) DRY=1 ;;
    *) args+=("$a") ;;
  esac
done
set -- "${args[@]+"${args[@]}"}"

if ! load_env "$ALERT_ENV"; then
  warn "alert.env fehlt oder ungültig ($ALERT_ENV) — nur Journal + Statusdateien"
fi

icon() {
  case "$1" in
    AUTH|TOKEN*|GIVEUP|API|REPO|DIRTY) echo "⛔" ;;
    HEARTBEAT|TEST) echo "✅" ;;
    *) echo "⚠" ;;
  esac
}
incident_hash() { printf '%s|%s' "$1" "${2:0:80}" | sha256sum | cut -c1-12; }

send_callmebot() {  # <text> → 0 queued · 1 Fehler · 2 nicht konfiguriert
  [ -n "${CALLMEBOT_PHONE:-}" ] && [ -n "${CALLMEBOT_APIKEY:-}" ] || return 2
  local body
  body="$("$CURL" -fsS -m 20 -G "https://api.callmebot.com/whatsapp.php" \
            --data-urlencode "phone=$CALLMEBOT_PHONE" \
            --data-urlencode "apikey=$CALLMEBOT_APIKEY" \
            --data-urlencode "text=$1" 2>/dev/null)" || return 1
  grep -qi "queued" <<<"$body"
}
send_ntfy() {  # <text> → 0 ok · 1 Fehler · 2 nicht konfiguriert
  [ -n "${NTFY_URL:-}" ] || [ -n "${NTFY_TOPIC:-}" ] || return 2
  "$CURL" -fsS -m 20 -H "Title: ai-news-dashboard" -H "Priority: high" \
    -d "$1" "${NTFY_URL:-https://ntfy.sh/${NTFY_TOPIC:-}}" >/dev/null 2>&1
}

# deliver <hash> <text> → 0 wenn mindestens ein Kanal zugestellt oder gedrosselt hat
deliver() {
  local hash="$1" text="$2" ch stamp rc any=1
  for ch in callmebot ntfy; do
    stamp="$STATE_DIR/sent.$ch.$hash"
    if [ "$FORCE" != 1 ] && [ -f "$stamp" ] \
       && [ $(( $(date +%s) - $(stat -c %Y "$stamp") )) -lt "$ALERT_REPEAT_SEC" ]; then
      any=0; continue
    fi
    if [ "$DRY" = 1 ]; then log "[dry-run] würde via $ch senden: $text"; any=0; continue; fi
    "send_$ch" "$text"; rc=$?
    case $rc in
      0) touch "$stamp"; any=0; log "zugestellt via $ch" ;;
      2) ;;
      *) warn "$ch fehlgeschlagen (rc=$rc)" ;;
    esac
  done
  return $any
}

raise() {  # <ART> <Text>
  local kind="$1" text="$2" hash msg
  hash="$(incident_hash "$kind" "$text")"
  msg="$(printf '%s ai-news [%s] %s' "$(icon "$kind")" "$kind" "$text")"
  logger -p user.err -t ai-news-alert "[$kind] $text" 2>/dev/null || true
  mkdir -p "$STATE_DIR"
  printf '%s\t%s\t%s\n' "$(date -Is)" "$kind" "$text" >> "$STATE_DIR/alerts.log"
  printf '%s\n%s\n%s\n' "$kind" "$(date -Is)" "$text" > "$STATE_DIR/last-alert"
  if deliver "$hash" "$msg"; then
    rm -f "$STATE_DIR/pending/$hash" "$STATE_DIR/pending/$hash.tries"
    return 0
  fi
  [ "$DRY" = 1 ] && return 0
  mkdir -p "$STATE_DIR/pending"
  [ -f "$STATE_DIR/pending/$hash.tries" ] || echo 0 > "$STATE_DIR/pending/$hash.tries"
  printf '%s\n' "$msg" > "$STATE_DIR/pending/$hash"
  warn "nicht zugestellt — pending ($hash)"
  return 1
}

resend() {
  local f hash tries n
  [ -d "$STATE_DIR/pending" ] || return 0
  for f in "$STATE_DIR"/pending/*; do
    [ -f "$f" ] || continue
    [[ "$f" == *.tries ]] && continue
    hash="$(basename "$f")"
    tries="$(cat "$f.tries" 2>/dev/null || echo 0)"
    if [ "$tries" -ge "$MAX_RESEND" ]; then
      n="$(find "$STATE_DIR/pending" -type f ! -name '*.tries' | wc -l)"
      if FORCE=1 deliver "summary-$(date +%G-%V)" \
           "⚠ ai-news: $n Alarm(e) konnten mehrfach nicht zugestellt werden. Details: $STATE_DIR/alerts.log"; then
        rm -rf "$STATE_DIR/pending"
      fi
      return 0
    fi
    if FORCE=1 deliver "$hash" "$(cat "$f")"; then
      rm -f "$f" "$f.tries"
    else
      echo $((tries + 1)) > "$f.tries"
    fi
  done
}

unit_failed() {  # <unit-präfix>, z.B. ai-news-dashboard-daily
  local unit="$1" short="${1#ai-news-dashboard-}" f kind text
  f="$STATE_DIR/last-failure.$short"
  if [ -f "$f" ] && [ $(( $(date +%s) - $(stat -c %Y "$f") )) -lt 7200 ]; then
    kind="$(sed -n 1p "$f")"; text="$(sed -n '2,$p' "$f" | tr '\n' ' ')"
  else
    kind="FAILED"
    text="$(journalctl -u "$unit.service" -n 5 --no-pager -o cat 2>/dev/null | tail -3 | tr '\n' ' ')"
  fi
  raise "${kind:-FAILED}" "${short}: ${text:-ohne Grund in State/Journal} · journalctl -u $unit.service"
}

case "${1:-}" in
  --test)      raise TEST "Alarmkanal-Test $(date '+%d.%m. %H:%M'), Briefing vom $(snapshot_date "$PROJECT_DIR/dashboards/ai-news/index.html")" ;;
  --resend)    resend ;;
  unit-failed) [ -n "${2:-}" ] || { echo "usage: alert.sh unit-failed <unit-präfix>" >&2; exit 64; }
               unit_failed "$2" ;;
  "")          sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 64 ;;
  *)           [ -n "${2:-}" ] || { echo "usage: alert.sh <ART> <Text…>" >&2; exit 64; }
               raise "$1" "${*:2}" ;;
esac
```

- [ ] **Step 4: Tests laufen lassen**

Run: `bash -n bin/alert.sh && chmod +x bin/alert.sh && bash tests/test-alert.sh`
Expected: alle `ok`, `0 fehlgeschlagen`.

- [ ] **Step 5: Echte Testnachricht (einmalig, mit der realen `alert.env`)**

Run: `bin/alert.sh --test`
Expected: Ausgabe `zugestellt via callmebot`, WhatsApp kommt an. (Die reale `alert.env` liegt seit 24.09. unter `~/.config/ai-news-dashboard/watchdog.env`; Task 7 benennt sie um. Für diesen Schritt: `ALERT_ENV=~/.config/ai-news-dashboard/watchdog.env bin/alert.sh --test`.)

- [ ] **Step 6: Commit**

```bash
git add bin/alert.sh tests/test-alert.sh
git commit -m "daily: alert.sh — Journal, Statusdateien, CallMeBot/ntfy, pending-Nachsenden

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: `bin/verify-briefing.sh`

**Files:**
- Create: `bin/verify-briefing.sh`
- Test: `tests/test-verify-briefing.sh`

**Interfaces:**
- Consumes: `bin/lib-daily.sh` (`PROJECT_DIR`, `snapshot_date`, `today`)
- Produces:
  - CLI: `verify-briefing.sh --pre-deploy|--full [--date YYYY-MM-DD] [--prev YYYY-MM-DD]`
  - Env-Schwellen: `MIN_WORDS` (Default 750, kalibriert: heutiges Briefing 1524 Wörter), `MIN_CARDS` (Default 2, heute 6)
  - stdout: eine Zeile pro Prüfung (`ok …` / `FAIL[not-deployed] …` / `FAIL[quality] …`), letzte Zeile `RESULT: ok` oder `RESULT: not-deployed: <grund>` oder `RESULT: quality: <grund>`
  - Exit: 0 ok · 6 not-deployed · 10 quality · 64 Usage
  - `--full` setzt voraus, dass der Aufrufer vorher `git fetch origin` gemacht hat (kein Netz im Skript)

- [ ] **Step 1: Fehlschlagenden Test schreiben**

`tests/test-verify-briefing.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
. tests/lib-test.sh; test_sandbox
export MIN_WORDS=50 MIN_CARDS=2
V="$PWD/bin/verify-briefing.sh"

# Synthetisches Repo mit gestern (D0) committet und heute (D1) im Tree
D1="$(date -I)"; D0="$(date -I -d "$D1 - 1 day")"
words() { local n=$1 s=""; while [ "$n" -gt 0 ]; do s="$s wort$n"; n=$((n-1)); done; echo "$s"; }
page() {  # page <datum> <modus> <wörter> <cards> <text-suffix>
  printf '<html><body data-snapshot-date="%s" data-snapshot-mode="%s">\n<div class="grid cols-3">\n' "$1" "$2"
  local i; for ((i=0;i<$4;i++)); do printf '<article class="card news-card info"><h3>Card %s</h3><p>x</p></article>\n' "$i"; done
  printf '</div>\n<article class="briefing-wrap"><p>%s %s</p></article>\n</body></html>\n' "$(words "$3")" "$5"
}
manifest() { printf '{"snapshots":[%s]}\n' "$1"; }
entry() { printf '{"date":"%s","url":"%s","headline":"h %s","summary":"s"}' "$1" "$2" "$1"; }

mk_repo() {
  R="$T_ROOT/repo"; rm -rf "$R"; mkdir -p "$R/dashboards/ai-news/archive" "$R/docs/ai-news/archive"
  git -C "$R" init -q -b main; git -C "$R" config user.email t@t; git -C "$R" config user.name t
  printf 'dashboards/ai-news/archive/*.html\ndashboards/ai-news/archive/manifest.json\n' > "$R/.gitignore"
  page "$D0" live 80 3 alt > "$R/dashboards/ai-news/index.html"
  manifest "$(entry "$D0" /ai-news/)" > "$R/dashboards/ai-news/archive/manifest.json"
  git -C "$R" add -A; git -C "$R" commit -qm gestern
  git init -q --bare "$T_ROOT/origin.git"; git -C "$R" remote add origin "$T_ROOT/origin.git"; git -C "$R" push -q -u origin main
  export PROJECT_DIR="$R"
}
good_today() {  # heutiges Briefing korrekt geschrieben (vor Build/Push)
  page "$D1" live 80 3 neu > "$R/dashboards/ai-news/index.html"
  page "$D0" archive 80 3 alt > "$R/dashboards/ai-news/archive/$D0.html"
  manifest "$(entry "$D0" "/ai-news/archive/$D0.html"),$(entry "$D1" /ai-news/)" > "$R/dashboards/ai-news/archive/manifest.json"
}
deploy_today() {  # Build (docs/) + commit + push simuliert
  cp "$R/dashboards/ai-news/index.html" "$R/docs/ai-news/index.html"
  cp "$R/dashboards/ai-news/archive/manifest.json" "$R/docs/ai-news/archive/manifest.json"
  git -C "$R" add -A; git -C "$R" commit -qm heute; git -C "$R" push -q origin main
}
run() { local rc=0; out="$("$V" "$@" 2>&1)" || rc=$?; echo "$rc"; }

mk_repo; good_today
assert_eq "0" "$(run --pre-deploy --date "$D1")" "pre-deploy ok"
assert_eq "6" "$(run --full --date "$D1")" "full vor Deploy → not-deployed"
deploy_today
assert_eq "0" "$(run --full --date "$D1")" "full nach Deploy ok"
assert_contains "RESULT: ok" "$out" "RESULT-Zeile"

# Datum-only-Update: Text identisch mit gestern → quality
mk_repo; good_today; page "$D1" live 80 3 alt > "$R/dashboards/ai-news/index.html"
assert_eq "10" "$(run --pre-deploy --date "$D1")" "identischer Text → quality"
assert_contains "identisch" "$out" "Grund identisch"

# zu wenig Wörter / zu wenig Cards
mk_repo; good_today; page "$D1" live 20 3 neu > "$R/dashboards/ai-news/index.html"
assert_eq "10" "$(run --pre-deploy --date "$D1")" "zu wenig Wörter → quality"
mk_repo; good_today; page "$D1" live 80 1 neu > "$R/dashboards/ai-news/index.html"
assert_eq "10" "$(run --pre-deploy --date "$D1")" "zu wenig Cards → quality"

# altes Datum → not-deployed
mk_repo
assert_eq "6" "$(run --pre-deploy --date "$D1")" "altes Datum → not-deployed"

# Archiv fehlt / falscher Modus
mk_repo; good_today; rm "$R/dashboards/ai-news/archive/$D0.html"
assert_eq "10" "$(run --pre-deploy --date "$D1")" "Archiv fehlt → quality"
mk_repo; good_today; page "$D0" live 80 3 alt > "$R/dashboards/ai-news/archive/$D0.html"
assert_eq "10" "$(run --pre-deploy --date "$D1")" "Archiv nicht im archive-Modus → quality"

# Manifest: doppeltes Datum / zwei Live-Einträge / Fremdfeld
mk_repo; good_today
manifest "$(entry "$D0" "/ai-news/archive/$D0.html"),$(entry "$D1" /ai-news/),$(entry "$D1" /ai-news/)" > "$R/dashboards/ai-news/archive/manifest.json"
assert_eq "10" "$(run --pre-deploy --date "$D1")" "doppelter Manifest-Eintrag → quality"
mk_repo; good_today
printf '{"snapshots":[%s,{"date":"%s","url":"/ai-news/","headline":"h","summary":"s","ticker":"x"}]}\n' "$(entry "$D0" "/ai-news/archive/$D0.html")" "$D1" > "$R/dashboards/ai-news/archive/manifest.json"
assert_eq "10" "$(run --pre-deploy --date "$D1")" "Fremdfeld im Manifest → quality"

# full: docs-Manifest weicht ab → quality; ahead → not-deployed
mk_repo; good_today; deploy_today
manifest "$(entry "$D0" "/ai-news/archive/$D0.html")" > "$R/docs/ai-news/archive/manifest.json"
git -C "$R" commit -qam "docs kaputt"; git -C "$R" push -q origin main
assert_eq "10" "$(run --full --date "$D1")" "docs-Manifest ≠ Quelle → quality"
mk_repo; good_today; cp "$R/dashboards/ai-news/index.html" "$R/docs/ai-news/index.html"
cp "$R/dashboards/ai-news/archive/manifest.json" "$R/docs/ai-news/archive/manifest.json"
git -C "$R" add -A; git -C "$R" commit -qm heute   # nicht gepusht
assert_eq "6" "$(run --full --date "$D1")" "ahead → not-deployed"

# Nachhollauf über Mitternacht: --date gestern, Briefing heute → ok
mk_repo; good_today
assert_eq "0" "$(run --pre-deploy --date "$D0")" "Datum ≥ Startdatum ok"
assert_rc 64 "usage" -- "$V"
test_summary
```

- [ ] **Step 2: Test laufen lassen, Fehlschlag sehen**

Run: `bash tests/test-verify-briefing.sh`
Expected: `FAIL`, weil `bin/verify-briefing.sh` fehlt.

- [ ] **Step 3: `bin/verify-briefing.sh` schreiben**

```bash
#!/usr/bin/env bash
#
# verify-briefing.sh — Ergebnisprüfung des Tageslaufs (Spec 5.3).
#   --pre-deploy   Inhalt, Archiv, Quell-Manifest (Prompt-Schritt 6, vor Build/Push)
#   --full         zusätzlich docs/, Tree clean, nichts ahead (Wrapper; Aufrufer hat gefetcht)
#   --date D       Startdatum des Laufs (Default heute); Briefing muss ≥ D sein
#   --prev D       Datum des vorherigen Live-Snapshots (Default: aus HEAD-Historie)
# Schwellen per Env: MIN_WORDS (750), MIN_CARDS (2).
# Exit: 0 ok · 6 not-deployed · 10 quality · 64 Usage
#
set -uo pipefail
LOG_TAG=verify
# shellcheck source=bin/lib-daily.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-daily.sh"

MODE=""; DATE="$(today)"; PREV=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pre-deploy|--full) MODE="${1#--}" ;;
    --date) DATE="$2"; shift ;;
    --prev) PREV="$2"; shift ;;
    *) echo "usage: verify-briefing.sh --pre-deploy|--full [--date D] [--prev D]" >&2; exit 64 ;;
  esac
  shift
done
[ -n "$MODE" ] || { echo "usage: verify-briefing.sh --pre-deploy|--full [--date D] [--prev D]" >&2; exit 64; }

cd "$PROJECT_DIR" || exit 64

# Vorheriger Live-Snapshot: erster HEAD-Stand von index.html, dessen Datum < aktuellem Datum
CUR_DATE="$(snapshot_date dashboards/ai-news/index.html)"
if [ -z "$PREV" ]; then
  for rev in HEAD HEAD~1 HEAD~2 HEAD~3; do
    d="$(git show "$rev:dashboards/ai-news/index.html" 2>/dev/null | grep -oE 'data-snapshot-date="[0-9-]{10}"' | head -1 | grep -oE '[0-9-]{10}' || true)"
    if [ -n "$d" ] && [[ "$d" < "$CUR_DATE" ]]; then PREV="$d"; PREV_REV="$rev"; break; fi
  done
fi
PREV_TEXT_FILE=""
if [ -n "$PREV" ]; then
  if [ -f "dashboards/ai-news/archive/$PREV.html" ]; then PREV_TEXT_FILE="dashboards/ai-news/archive/$PREV.html"
  elif [ -n "${PREV_REV:-}" ]; then git show "$PREV_REV:dashboards/ai-news/index.html" > "$STATE_DIR/prev-index.html" 2>/dev/null && PREV_TEXT_FILE="$STATE_DIR/prev-index.html"; fi
fi

CLEAN=1; AHEAD=0
if [ "$MODE" = full ]; then
  [ -z "$(git status --porcelain --untracked-files=all)" ] || CLEAN=0
  AHEAD="$(git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)"
fi

python3 - "$MODE" "$DATE" "$PREV" "$PREV_TEXT_FILE" "$CLEAN" "$AHEAD" <<'PY'
import json, os, re, sys, html
mode, run_date, prev, prev_file, clean, ahead = sys.argv[1:7]
MIN_WORDS = int(os.environ.get("MIN_WORDS", "750")); MIN_CARDS = int(os.environ.get("MIN_CARDS", "2"))
fails = []   # (klasse, grund)
def ok(msg): print("ok  " + msg)
def fail(cls, msg): fails.append((cls, msg)); print(f"FAIL[{cls}] {msg}")
def read(p):
    try: return open(p, encoding="utf-8", errors="replace").read()
    except FileNotFoundError: return None
def sdate(s): m = re.search(r'data-snapshot-date="(\d{4}-\d{2}-\d{2})"', s or ""); return m.group(1) if m else ""
def smode(s): m = re.search(r'data-snapshot-mode="(\w+)"', s or ""); return m.group(1) if m else ""
def briefing_text(s):
    m = re.search(r'<article class="briefing-wrap">(.*?)</article>', s or "", re.S)
    return " ".join(html.unescape(re.sub(r"<[^>]+>", " ", m.group(1))).split()) if m else ""

src = read("dashboards/ai-news/index.html") or ""
d = sdate(src)
if d and d >= run_date: ok(f"Snapshot-Datum {d} ≥ Startdatum {run_date}")
else: fail("not-deployed", f"Snapshot-Datum {d or 'fehlt'} < Startdatum {run_date}")

text = briefing_text(src); words = len(text.split())
if words >= MIN_WORDS: ok(f"Briefing {words} Wörter (≥ {MIN_WORDS})")
else: fail("quality", f"Briefing nur {words} Wörter (< {MIN_WORDS})")
cards = len(re.findall(r'<article class="card news-card', src))
if cards >= MIN_CARDS: ok(f"{cards} Breaking-Cards (≥ {MIN_CARDS})")
else: fail("quality", f"nur {cards} Breaking-Cards (< {MIN_CARDS})")
prev_src = read(prev_file) if prev_file else None
if prev_src is not None:
    if text and text == briefing_text(prev_src): fail("quality", f"Briefing-Text identisch mit Snapshot {prev}")
    else: ok(f"Briefing-Text unterscheidet sich von {prev}")
else: ok("kein vorheriger Snapshot zum Vergleich (erster Lauf)")

if prev:
    arch = read(f"dashboards/ai-news/archive/{prev}.html")
    if arch is None: fail("quality", f"archive/{prev}.html fehlt")
    elif smode(arch) != "archive": fail("quality", f"archive/{prev}.html hat data-snapshot-mode={smode(arch)!r}, nicht archive")
    else: ok(f"archive/{prev}.html vorhanden, Modus archive")

def check_manifest(path, label):
    raw = read(path)
    if raw is None: fail("quality", f"{label} fehlt"); return None
    try: m = json.loads(raw)
    except Exception as e: fail("quality", f"{label} kein valides JSON: {e}"); return None
    items = m.get("snapshots") if isinstance(m, dict) else None
    if not isinstance(items, list): fail("quality", f"{label}: kein 'snapshots'-Array"); return None
    allowed = {"date", "url", "headline", "summary"}
    bad = [e.get("date") for e in items if set(e) != allowed]
    if bad: fail("quality", f"{label}: Einträge mit falschen Feldern: {bad}")
    dates = [e.get("date") for e in items]
    dups = sorted({x for x in dates if dates.count(x) > 1})
    if dups: fail("quality", f"{label}: doppelte Daten {dups}")
    live = [e for e in items if e.get("url") == "/ai-news/"]
    if len(live) != 1: fail("quality", f"{label}: {len(live)} Live-Einträge (/ai-news/), erwartet 1")
    elif live[0].get("date", "") < run_date: fail("quality", f"{label}: Live-Eintrag datiert {live[0].get('date')} < {run_date}")
    else: ok(f"{label}: genau ein Live-Eintrag ({live[0]['date']})")
    if prev and not any(e.get("date") == prev and e.get("url") == f"/ai-news/archive/{prev}.html" for e in items):
        fail("quality", f"{label}: kein Archiv-Eintrag für {prev}")
    return [(e.get("date"), e.get("url")) for e in items]

src_entries = check_manifest("dashboards/ai-news/archive/manifest.json", "manifest.json")

if mode == "full":
    doc = read("docs/ai-news/index.html") or ""
    if sdate(doc) == d: ok(f"docs/ai-news/index.html Datum {sdate(doc)}")
    else: fail("not-deployed", f"docs/ai-news/index.html Datum {sdate(doc) or 'fehlt'} ≠ {d}")
    doc_entries = check_manifest("docs/ai-news/archive/manifest.json", "docs-manifest")
    if src_entries is not None and doc_entries is not None:
        if sorted(src_entries) == sorted(doc_entries): ok("docs-Manifest == Quell-Manifest")
        else: fail("quality", "docs-Manifest weicht vom Quell-Manifest ab (date/url)")
    if clean == "1": ok("Working Tree clean")
    else: fail("not-deployed", "Working Tree nicht clean")
    if ahead == "0": ok("nichts ahead von origin/main")
    else: fail("not-deployed", f"{ahead} Commit(s) nicht gepusht")

if not fails: print("RESULT: ok"); sys.exit(0)
nd = [f for f in fails if f[0] == "not-deployed"]
if nd: print("RESULT: not-deployed: " + nd[0][1]); sys.exit(6)
print("RESULT: quality: " + fails[0][1]); sys.exit(10)
PY
```

- [ ] **Step 4: Tests laufen lassen**

Run: `bash -n bin/verify-briefing.sh && chmod +x bin/verify-briefing.sh && bash tests/test-verify-briefing.sh`
Expected: alle `ok`, `0 fehlgeschlagen`.

- [ ] **Step 5: Gegen das echte Repo prüfen (Kalibrierung)**

Run: `git fetch origin && bin/verify-briefing.sh --full`
Expected: Exit 0, `RESULT: ok`, Zeile `Briefing 1524 Wörter (≥ 750)` (Zahl vom Tag des Laufs). Wenn hier etwas rot ist, sind die Schwellen oder die Markup-Annahmen falsch — vor dem Commit klären, nicht die Schwelle senken.

- [ ] **Step 6: Commit**

```bash
git add bin/verify-briefing.sh tests/test-verify-briefing.sh
git commit -m "daily: verify-briefing.sh — Ergebnisprüfung pre-deploy/full

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Klassifikation in `bin/lib-daily.sh`

**Files:**
- Modify: `bin/lib-daily.sh` (am Ende anhängen)
- Create: `tests/fixtures/result-ok.json`, `result-401.json`, `result-404.json`, `result-budget.json`, `result-blocked.json`, `result-nojson.txt`
- Test: `tests/test-classify.sh`

**Interfaces:**
- Produces:
  - `classify_result <json-datei>` → druckt `<code> <ART> <text>` (Codes 0/3/5/7/8 laut Spec 5.2); liest nie stdin
  - `classify_dirt` → liest `git status --porcelain --untracked-files=all` von stdin, druckt `clean` | `own` | `foreign`
  - `OWN_DIRT_PATHS` (Array): `dashboards/ai-news` `dashboards/it-services` `docs`

- [ ] **Step 1: Fixtures anlegen** (Felder wie am 24.09. mit CLI 2.1.281 gemessen)

`tests/fixtures/result-ok.json`:
```json
{"type":"result","subtype":"success","is_error":false,"api_error_status":null,"terminal_reason":"completed","num_turns":42,"total_cost_usd":4.21,"session_id":"11111111-2222-3333-4444-555555555555","result":"Alles erledigt.\nSTATUS: Lauf vom 2026-09-24: 6 Items, 1524 Wörter, Deploy ✓\nPersonen-Vorschlag: keiner"}
```
`tests/fixtures/result-401.json`:
```json
{"type":"result","subtype":"success","is_error":true,"api_error_status":401,"terminal_reason":"api_error","num_turns":1,"result":"Failed to authenticate. API Error: 401 OAuth access token is invalid."}
```
`tests/fixtures/result-404.json`:
```json
{"type":"result","subtype":"success","is_error":true,"api_error_status":404,"terminal_reason":"api_error","num_turns":1,"result":"API Error: 404 model: claude-opus-4-8 not found"}
```
`tests/fixtures/result-budget.json`:
```json
{"type":"result","subtype":"error_max_budget_usd","is_error":true,"terminal_reason":"budget_exhausted","num_turns":3,"total_cost_usd":30.02,"errors":["max budget exceeded"]}
```
`tests/fixtures/result-blocked.json`:
```json
{"type":"result","subtype":"success","is_error":false,"api_error_status":null,"terminal_reason":"completed","num_turns":9,"result":"Quellen liefern seit 3 Versuchen 5xx.\nBLOCKED: WebSearch dauerhaft nicht erreichbar"}
```
`tests/fixtures/result-nojson.txt`:
```
Segmentation fault (core dumped)
```

- [ ] **Step 2: Fehlschlagenden Test schreiben**

`tests/test-classify.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
. tests/lib-test.sh; test_sandbox
. bin/lib-daily.sh
F=tests/fixtures
assert_eq "0 OK" "$(classify_result $F/result-ok.json | cut -d' ' -f1-2)" "ok"
assert_eq "3 AUTH" "$(classify_result $F/result-401.json | cut -d' ' -f1-2)" "401 → 3"
assert_eq "8 API" "$(classify_result $F/result-404.json | cut -d' ' -f1-2)" "404 → 8"
assert_eq "8 API" "$(classify_result $F/result-budget.json | cut -d' ' -f1-2)" "budget → 8 (ohne result-Feld)"
assert_eq "7 BLOCKED" "$(classify_result $F/result-blocked.json | cut -d' ' -f1-2)" "BLOCKED → 7"
assert_contains "WebSearch" "$(classify_result $F/result-blocked.json)" "BLOCKED-Text"
assert_eq "5 RUN" "$(classify_result $F/result-nojson.txt | cut -d' ' -f1-2)" "kein JSON → 5"
assert_eq "5 RUN" "$(classify_result /nonexistent.json | cut -d' ' -f1-2)" "fehlende Datei → 5"
printf '{"is_error":true,"api_error_status":529,"terminal_reason":"api_error","result":"overloaded"}' > "$T_ROOT/529.json"
assert_eq "5 RUN" "$(classify_result "$T_ROOT/529.json" | cut -d' ' -f1-2)" "529 → 5"
printf '{"is_error":false,"terminal_reason":"max_turns","result":"…"}' > "$T_ROOT/mt.json"
assert_eq "5 RUN" "$(classify_result "$T_ROOT/mt.json" | cut -d' ' -f1-2)" "max_turns → 5"

assert_eq "clean" "$(printf '' | classify_dirt)" "clean"
assert_eq "own" "$(printf ' M dashboards/ai-news/index.html\n?? docs/ai-news/archive/x.html\n M dashboards/it-services/index.html\n' | classify_dirt)" "own"
assert_eq "foreign" "$(printf ' M dashboards/ai-news/index.html\n M bin/check.sh\n' | classify_dirt)" "foreign (bin)"
assert_eq "foreign" "$(printf '?? notizen.txt\n' | classify_dirt)" "foreign (untracked root)"
assert_eq "own" "$(printf 'R  docs/a.html -> docs/b.html\n' | classify_dirt)" "rename → Zielpfad"
assert_eq "foreign" "$(printf ' M "dashboards/ai-news/x y.html"\n M DAILY_UPDATE.md\n' | classify_dirt)" "quoted + foreign"
test_summary
```

- [ ] **Step 3: Test laufen lassen, Fehlschlag sehen**

Run: `bash tests/test-classify.sh`
Expected: `classify_result: command not found`.

- [ ] **Step 4: Funktionen an `bin/lib-daily.sh` anhängen**

```bash

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
```

- [ ] **Step 5: Tests laufen lassen**

Run: `bash -n bin/lib-daily.sh && bash tests/test-classify.sh && bash tests/run-all.sh`
Expected: alle `ok`, `ALLE TESTS OK`.

- [ ] **Step 6: Commit**

```bash
git add bin/lib-daily.sh tests/test-classify.sh tests/fixtures/
git commit -m "daily: Klassifikation von claude-p-Ergebnis und Working-Tree-Dirt

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: `bin/run-daily.sh`

**Files:**
- Create: `bin/run-daily.sh`
- Test: `tests/test-run-daily.sh`

**Interfaces:**
- Consumes: `bin/lib-daily.sh` (`load_env`, `resolve_claude`, `classify_result`, `classify_dirt`, `OWN_DIRT_PATHS`, `snapshot_date`, `state_*`, `today`), `bin/verify-briefing.sh --full --date D [--prev P]`
- Produces:
  - CLI: `run-daily.sh` · `run-daily.sh --dry-run` · `run-daily.sh --reset-attempts`; Env-Haken `DAILY_ENV`, `ALERT_ENV`, `LOCK_WAIT_SEC` (Default 300), `MAX_ATTEMPTS` (3), `CLAUDE_SETTING_SOURCES` (leer; Phase 3c setzt ggf. `project`)
  - Exit-Codes exakt wie Spec 5.2; `--dry-run` endet 0 nach dem Preflight („würde …") oder mit dem Preflight-Code (3/4/9), schreibt keinen State
  - Dateien in `$STATE_DIR`: `run.lock`, `attempts.<datum>`, `last-run.out.json` (stdout von `claude -p`), `last-run.json` (Zeit, Dauer, Exit, ART, Text, Kosten, Turns, session_id, CLI-Version, `STATUS:`-Zeile), `last-failure.daily` (Zeile 1 ART, Zeile 2 Text), `manifest.bak`, `prev-snapshot`
  - Env aus `daily.env`: `CLAUDE_CODE_OAUTH_TOKEN` (Pflicht), `CLAUDE_MODEL` (Default `claude-opus-4-8`), `FALLBACK_MODEL` (optional), `MAX_BUDGET_USD` (Default 30); aus `alert.env`: `HEALTHCHECKS_URL` (optional)

- [ ] **Step 1: Fehlschlagenden Test schreiben**

`tests/test-run-daily.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
. tests/lib-test.sh; test_sandbox
BIN="$PWD/bin"; FIX="$PWD/tests/fixtures"
export MIN_WORDS=50 MIN_CARDS=2 LOCK_WAIT_SEC=1
export DAILY_ENV="$CONF_DIR/daily.env" ALERT_ENV="$CONF_DIR/alert.env"
printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-test\nCLAUDE_MODEL=test-model\nMAX_BUDGET_USD=1\n' > "$DAILY_ENV"
printf 'HEALTHCHECKS_URL=https://hc.example/uuid\n' > "$ALERT_ENV"
D1="$(date -I)"; D0="$(date -I -d "$D1 - 1 day")"
stub logger 'exit 0'

# Generator für synthetische Seiten (auch vom claude-Stub genutzt)
cat > "$T_ROOT/gen.sh" <<'GEN'
words() { local n=$1 s=""; while [ "$n" -gt 0 ]; do s="$s wort$n"; n=$((n-1)); done; echo "$s"; }
page() { printf '<html><body data-snapshot-date="%s" data-snapshot-mode="%s">\n<div class="grid cols-3">\n' "$1" "$2"
  local i; for ((i=0;i<$4;i++)); do printf '<article class="card news-card info"><h3>C%s</h3></article>\n' "$i"; done
  printf '</div>\n<article class="briefing-wrap"><p>%s %s</p></article>\n</body></html>\n' "$(words "$3")" "$5"; }
entry() { printf '{"date":"%s","url":"%s","headline":"h %s","summary":"s"}' "$1" "$2" "$1"; }
manifest() { printf '{"snapshots":[%s]}\n' "$1"; }
GEN
. "$T_ROOT/gen.sh"

mk_repo() {
  R="$T_ROOT/repo"; rm -rf "$R" "$T_ROOT/origin.git"; mkdir -p "$R/dashboards/ai-news/archive" "$R/docs/ai-news/archive" "$R/bin"
  git -C "$R" init -q -b main; git -C "$R" config user.email t@t; git -C "$R" config user.name t
  printf 'dashboards/ai-news/archive/*.html\ndashboards/ai-news/archive/manifest.json\n' > "$R/.gitignore"
  page "$D0" live 80 3 alt > "$R/dashboards/ai-news/index.html"; cp "$R/dashboards/ai-news/index.html" "$R/docs/ai-news/index.html"
  manifest "$(entry "$D0" /ai-news/)" > "$R/dashboards/ai-news/archive/manifest.json"; cp "$R/dashboards/ai-news/archive/manifest.json" "$R/docs/ai-news/archive/manifest.json"
  echo prompt > "$R/DAILY_UPDATE.md"
  git -C "$R" add -A; git -C "$R" commit -qm gestern
  git init -q --bare "$T_ROOT/origin.git"; git -C "$R" remote add origin "$T_ROOT/origin.git"; git -C "$R" push -q -u origin main
  # Skripte aus dem echten bin/ verlinken, damit run-daily.sh seine Nachbarn findet
  ln -sf "$BIN/lib-daily.sh" "$BIN/verify-briefing.sh" "$BIN/run-daily.sh" "$R/bin/"
  export PROJECT_DIR="$R"; rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"; : > "$STUB_BIN/claude.log"
}
# claude-Stub: CLAUDE_STUB=<fixture|ok-full|ok-nothing|half-then-529>
stub claude 'echo "$@" >> "$STUB_BIN/claude.log"
[ "${1:-}" = "--version" ] && { echo "stub 0.0"; exit 0; }
. "$T_ROOT/gen.sh"; cd "$PROJECT_DIR"
D1="$(date -I)"; D0="$(date -I -d "$D1 - 1 day")"
write_today() { page "$D1" live 80 3 neu > dashboards/ai-news/index.html
  page "$D0" archive 80 3 alt > "dashboards/ai-news/archive/$D0.html"
  manifest "$(entry "$D0" "/ai-news/archive/$D0.html"),$(entry "$D1" /ai-news/)" > dashboards/ai-news/archive/manifest.json; }
case "$CLAUDE_STUB" in
  ok-full) write_today; cp dashboards/ai-news/index.html docs/ai-news/index.html; cp dashboards/ai-news/archive/manifest.json docs/ai-news/archive/manifest.json
           git add dashboards docs; git commit -qm "daily: briefing $D1"; git push -q origin main; cat "$FIX/result-ok.json" ;;
  ok-nothing) cat "$FIX/result-ok.json" ;;
  half-then-529) page "$D1" live 10 1 halb > dashboards/ai-news/index.html; echo "{}" > dashboards/ai-news/archive/manifest.json
           printf "{\"is_error\":true,\"api_error_status\":529,\"terminal_reason\":\"api_error\",\"result\":\"overloaded\"}"; exit 1 ;;
  *) cat "$FIX/$CLAUDE_STUB"; exit 1 ;;
esac'
export FIX T_ROOT
stub curl 'printf "<body data-snapshot-date=\"%s\">" "$(date -I)"; echo "$@" >> "$STUB_BIN/curl.log"'
run() { local rc=0; out="$(cd "$R" && "$R/bin/run-daily.sh" "$@" 2>&1 </dev/null)" || rc=$?; echo "$rc"; }

# 1. Token fehlt → 3, kein State
mk_repo; : > "$DAILY_ENV"
assert_eq "3" "$(run)" "Token fehlt → 3"; assert_eq "AUTH" "$(sed -n 1p "$STATE_DIR/last-failure.daily")" "last-failure AUTH"
printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-test\nCLAUDE_MODEL=test-model\nMAX_BUDGET_USD=1\n' > "$DAILY_ENV"

# 2. fremder Dirt → 4
mk_repo; echo x > "$R/notiz.txt"
assert_eq "4" "$(run)" "fremder Dirt → 4"; assert_contains "notiz.txt" "$out" "Pfad im Text"

# 3. idempotent: heute schon gepusht → 0, claude nicht aufgerufen
mk_repo; CLAUDE_STUB=ok-full "$STUB_BIN/claude" >/dev/null 2>&1; : > "$STUB_BIN/claude.log"
assert_eq "0" "$(run)" "schon erledigt → 0"; assert_eq "" "$(cat "$STUB_BIN/claude.log")" "claude nicht aufgerufen"

# 4. push-only: committet, nicht gepusht → pusht, 0, claude nicht aufgerufen
mk_repo; ( cd "$R" && . "$T_ROOT/gen.sh" && page "$D1" live 80 3 neu > dashboards/ai-news/index.html && page "$D0" archive 80 3 alt > "dashboards/ai-news/archive/$D0.html" \
  && manifest "$(entry "$D0" "/ai-news/archive/$D0.html"),$(entry "$D1" /ai-news/)" > dashboards/ai-news/archive/manifest.json \
  && cp dashboards/ai-news/index.html docs/ai-news/index.html && cp dashboards/ai-news/archive/manifest.json docs/ai-news/archive/manifest.json \
  && git add -A && git commit -qm heute ); : > "$STUB_BIN/claude.log"
assert_eq "0" "$(run)" "push-only → 0"; assert_eq "" "$(cat "$STUB_BIN/claude.log")" "push-only ohne claude"
assert_eq "0" "$(git -C "$R" rev-list --count origin/main..HEAD)" "gepusht"

# 5. 401 → 3
mk_repo; export CLAUDE_STUB=result-401.json
assert_eq "3" "$(run)" "401 → 3"; assert_contains "AUTH" "$(cat "$STATE_DIR/last-failure.daily")" "AUTH im last-failure"
assert_eq "" "$(cat "$STATE_DIR/attempts.$D1" 2>/dev/null)" "AUTH zählt nicht als Versuch"

# 6. 3× 529 → 5, 5, 11 (GIVEUP)
mk_repo; export CLAUDE_STUB=result-529.json
printf '{"is_error":true,"api_error_status":529,"terminal_reason":"api_error","result":"overloaded"}' > "$FIX/result-529.json"
assert_eq "5" "$(run)" "529 #1 → 5"; assert_eq "1" "$(cat "$STATE_DIR/attempts.$D1")" "attempts=1"
assert_eq "5" "$(run)" "529 #2 → 5"; assert_eq "2" "$(cat "$STATE_DIR/attempts.$D1")" "attempts=2"
assert_eq "11" "$(run)" "529 #3 → 11 GIVEUP"; assert_eq "GIVEUP" "$(sed -n 1p "$STATE_DIR/last-failure.daily")" "GIVEUP im last-failure"
assert_contains "/fail" "$(cat "$STUB_BIN/curl.log")" "healthchecks /fail bei GIVEUP"
rm -f "$FIX/result-529.json"

# 7. Lauf ohne Ergebnis → 6
mk_repo; export CLAUDE_STUB=ok-nothing
assert_eq "6" "$(run)" "kein Ergebnis → 6"; assert_contains "OUTCOME" "$(cat "$STATE_DIR/last-failure.daily")" "OUTCOME"

# 8. Teillauf + 529 → 5, Reste gestasht, Manifest zurück, Tree clean
mk_repo; export CLAUDE_STUB=half-then-529
assert_eq "5" "$(run)" "Teillauf → 5"
assert_eq "" "$(git -C "$R" status --porcelain --untracked-files=all)" "Tree nach Cleanup clean"
assert_eq "1" "$(git -C "$R" stash list | wc -l)" "Stash angelegt"
assert_contains "\"url\":\"/ai-news/\"" "$(cat "$R/dashboards/ai-news/archive/manifest.json")" "Manifest zurückgesetzt"

# 9. voller Erfolg → 0, last-run.json, Zähler weg
mk_repo; export CLAUDE_STUB=ok-full; echo 1 > "$STATE_DIR/attempts.$D1"
assert_eq "0" "$(run)" "Erfolg → 0"
assert_eq "0" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["exit"])' "$STATE_DIR/last-run.json")" "last-run exit 0"
assert_contains "STATUS: Lauf vom" "$(cat "$STATE_DIR/last-run.json")" "STATUS-Zeile gespeichert"
assert_eq "" "$(cat "$STATE_DIR/attempts.$D1" 2>/dev/null)" "Zähler gelöscht"
assert_contains -- "--strict-mcp-config" "$(cat "$STUB_BIN/claude.log")" "strict-mcp-config gesetzt"
assert_contains "AskUserQuestion" "$(cat "$STUB_BIN/claude.log")" "AskUserQuestion gesperrt"

# 10. dry-run: Token fehlt → 3; sonst 0 ohne claude
mk_repo; : > "$DAILY_ENV"; assert_eq "3" "$(run --dry-run)" "dry-run ohne Token → 3"
printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-test\n' > "$DAILY_ENV"; : > "$STUB_BIN/claude.log"
assert_eq "0" "$(run --dry-run)" "dry-run → 0"; assert_contains "würde claude -p starten" "$out" "dry-run Text"
assert_eq "" "$(cat "$STUB_BIN/claude.log")" "dry-run ohne claude"

# 11. Lock belegt → 0 ohne Alarm
mk_repo; ( exec 9>"$STATE_DIR/run.lock"; flock 9; sleep 3 ) & sleep 0.3
assert_eq "0" "$(run)" "Lock belegt → 0"; assert_contains "Lock" "$out" "Lock-Hinweis"; wait
test_summary
```

- [ ] **Step 2: Test laufen lassen, Fehlschlag sehen**

Run: `bash tests/test-run-daily.sh`
Expected: `FAIL`, weil `bin/run-daily.sh` fehlt (Symlink zeigt ins Leere).

- [ ] **Step 3: `bin/run-daily.sh` schreiben**

```bash
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
CLAUDE_BIN=""
attempts="$(state_read "attempts.$RUN_DATE")"; attempts="${attempts:-0}"

ping_hc() {  # ping_hc start|fail|"" — nur wenn HEALTHCHECKS_URL gesetzt
  [ -n "${HEALTHCHECKS_URL:-}" ] || return 0
  curl -fsS -m 10 "$HEALTHCHECKS_URL${1:+/$1}" >/dev/null 2>&1 || true
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
    if git stash push -u -q -m "daily-fail $(date -Is) exit $1" -- "${OWN_DIRT_PATHS[@]}"; then
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
    d="$(curl -fsS -m 15 -H 'Cache-Control: no-cache' "$PAGES_URL" 2>/dev/null \
          | grep -oE 'data-snapshot-date="[0-9-]{10}"' | head -1 | grep -oE '[0-9-]{10}' || true)"
    if [ -n "$d" ] && [[ ! "$d" < "$RUN_DATE" ]]; then log "Pages zeigt $d"; return 0; fi
    [ "$i" -lt 10 ] && sleep 60
  done
  warn "Pages zeigt nach 10 min noch ${d:-nichts} — der Watchdog meldet PUBLIC_STALE, falls es so bleibt"
}

verify_and_finish() {
  local vout vrc=0 reason prev status
  prev="$(state_read prev-snapshot)"
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
  poll_pages
  return 0
}

push_only() {
  local out
  if out="$(git push origin main 2>&1)"; then
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

  # 1. Lock (paralleler Handlauf ist kein Alarm)
  exec 9>"$STATE_DIR/run.lock"
  if ! flock -w "$LOCK_WAIT_SEC" 9; then
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
      if [ "$DRY" = 1 ]; then log "[dry-run] würde die Reste stashen"
      else git stash push -u -q -m "daily-leftover $(date -Is)" -- "${OWN_DIRT_PATHS[@]}" || fail 5 RUN "git stash der Reste fehlgeschlagen"; fi ;;
  esac

  # 4. Repo (nach dem Stash, sonst liefe der Lauf auf veralteter Basis)
  if [ -f .git/index.lock ] && [ $(( $(date +%s) - $(stat -c %Y .git/index.lock) )) -gt 3600 ]; then
    rm -f .git/index.lock; warn "verwaistes .git/index.lock entfernt"
  fi
  if ! fetch_out="$(git fetch origin 2>&1)"; then
    if grep -qiE "authentication failed|could not read username|403" <<<"$fetch_out"; then
      fail 9 REPO "GitHub-Auth beim Fetch fehlgeschlagen — 'gh auth status' prüfen"
    fi
    fail 5 RUN "git fetch fehlgeschlagen: ${fetch_out:0:120}"
  fi
  if [ "$DRY" != 1 ]; then
    git merge --ff-only -q origin/main 2>/dev/null || fail 9 REPO "lokal und origin/main divergieren — von Hand rebasen"
  fi

  # 5. Idempotenz / push-only
  cur="$(snapshot_date dashboards/ai-news/index.html)"
  ahead="$(git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)"
  if [ "$cur" = "$RUN_DATE" ] && [ "$(git status --porcelain --untracked-files=all | classify_dirt)" = clean ]; then
    if [ "$ahead" = 0 ]; then log "Briefing vom $RUN_DATE ist gepusht — nichts zu tun"; exit 0; fi
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
      --max-budget-usd "$MAX_BUDGET_USD" "$prompt" >"$out" </dev/null || rc=$?
  log "claude -p beendet mit rc=$rc nach $(( $(date +%s) - START_TS )) s"

  # 8. Klassifikation
  cls="$(classify_result "$out")"
  code="${cls%% *}"; kind="$(cut -d' ' -f2 <<<"$cls")"; text="$(cut -d' ' -f3- <<<"$cls")"
  [ "$code" = 0 ] || fail "$code" "$kind" "$text"
  grep -q '"permission_denials": *\[[^]]' "$out" 2>/dev/null && warn "permission_denials nicht leer — der Lauf konnte nicht alles ausführen"

  # 9./10. Ergebnis, State, Pages
  verify_and_finish
  exit 0
}

main
```

- [ ] **Step 4: Tests laufen lassen**

Run: `bash -n bin/run-daily.sh && chmod +x bin/run-daily.sh && bash tests/test-run-daily.sh`
Expected: alle `ok`, `0 fehlgeschlagen`. Testfall 8 dauert wegen `LOCK_WAIT_SEC=1` und Stash wenige Sekunden; Fall 11 wartet 3 s.

- [ ] **Step 5: Dry-Run gegen das echte Repo**

Run: `DAILY_ENV=/dev/null bin/run-daily.sh --dry-run </dev/null; echo rc=$?`
Expected: `⚠ [AUTH] CLAUDE_CODE_OAUTH_TOKEN fehlt …`, `rc=3` (der echte Token existiert erst nach Phase 0). Danach mit einer Test-Env, die nur `CLAUDE_CODE_OAUTH_TOKEN=x` enthält: `rc=0` und eine Zeile „Briefing vom <heute> ist gepusht — nichts zu tun" oder „würde claude -p starten".

- [ ] **Step 6: Commit**

```bash
git add bin/run-daily.sh tests/test-run-daily.sh
git commit -m "daily: run-daily.sh — Tageslauf mit Preflight, Klassifikation, Verify, Cleanup, Zähler

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: `bin/watchdog.sh`

**Files:**
- Create: `bin/watchdog.sh`
- Test: `tests/test-watchdog.sh`

**Interfaces:**
- Consumes: `bin/lib-daily.sh`, `bin/alert.sh` (`<ART> <Text>`, `--resend`, `--force`), `$STATE_DIR/last-run.json`, `last-alert`; Kommandos `systemctl show`, `gh auth status`, `gh run list`, `curl`, `claude` (alle per PATH stubbar)
- Produces:
  - CLI: `watchdog.sh` (Prüfen + Alarmieren, Exit 0) · `watchdog.sh --dry-run` (nur zeigen; Exit 0 gesund, 1 wenn ein Alarm anstünde — nutzt `check.sh`)
  - Test-Haken: `WD_NOW_HOUR`, `WD_NOW_DOW` (1–7), `WD_NOW_WEEK` (`YYYY-WW`)
  - Stempel in `$STATE_DIR`: `wd.token-warn` (Datum), `wd.token-live` (Woche), `wd.heartbeat` (Woche), `wd.failed-invocation` (InvocationID), `wd.gh-auth` (Datum)
  - Alarm-Arten: `TOKEN`, `TOKEN_LIVE`, `STALE`, `PUBLIC_STALE`, `YOUTUBE`, `FAILED`, `GH_AUTH`, `HEARTBEAT`

- [ ] **Step 1: Fehlschlagenden Test schreiben**

`tests/test-watchdog.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
. tests/lib-test.sh; test_sandbox
BIN="$PWD/bin"
export DAILY_ENV="$CONF_DIR/daily.env" ALERT_ENV="$CONF_DIR/alert.env" ALERT_CURL="$STUB_BIN/curl"
D1="$(date -I)"; D0="$(date -I -d "$D1 - 1 day")"; D3="$(date -I -d "$D1 - 3 day")"
stub logger 'exit 0'
stub curl 'echo "$@" >> "$STUB_BIN/curl.log"
case "$*" in *callmebot*) echo "Message queued";; *) printf "<body data-snapshot-date=\"%s\">" "${PAGES_DATE:-$(date -I)}";; esac'
stub systemctl 'printf "ActiveState=%s\nSubState=%s\nResult=%s\nInvocationID=%s\n" "${UNIT_ACTIVE:-inactive}" dead "${UNIT_RESULT:-success}" "${UNIT_INV:-aaa}"'
stub gh 'case "$1" in auth) exit "${GH_AUTH_RC:-0}";; run) echo "success 2026-09-24T16:17:00Z";; esac'
stub claude 'echo "$@" >> "$STUB_BIN/claude.log"; echo "{\"is_error\":${CLAUDE_LIVE_ERR:-false},\"result\":\"OK\"}"'
stub timeout 'shift; exec "$@"'
export PROJECT_DIR="$T_ROOT/proj"; mkdir -p "$PROJECT_DIR/dashboards/ai-news" "$PROJECT_DIR/dashboards/youtube"

setup() {  # setup <briefing-datum> <token-created> [youtube-age-h]
  rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"; : > "$STUB_BIN/curl.log"; : > "$STUB_BIN/claude.log"
  printf '<body data-snapshot-date="%s" data-snapshot-mode="live">' "$1" > "$PROJECT_DIR/dashboards/ai-news/index.html"
  printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-x\nTOKEN_CREATED=%s\nCLAUDE_MODEL=m\n' "$2" > "$DAILY_ENV"
  printf 'CALLMEBOT_PHONE=1\nCALLMEBOT_APIKEY=k\nHEARTBEAT=1\n' > "$ALERT_ENV"
  echo '{}' > "$PROJECT_DIR/dashboards/youtube/data.json"; touch -d "-${3:-1} hours" "$PROJECT_DIR/dashboards/youtube/data.json"
  printf '{"date":"%s","finished":"%sT08:00:00+0200","exit":0,"kind":"OK"}' "$1" "$1" > "$STATE_DIR/last-run.json"
  touch -d "-3 hours" "$STATE_DIR/last-run.json"
}
kinds() { cut -f2 "$STATE_DIR/alerts.log" 2>/dev/null | sort -u | tr '\n' ' '; }
run() { local rc=0; out="$("$BIN/watchdog.sh" "$@" 2>&1)" || rc=$?; echo "$rc"; }

# 1. alles frisch → kein Alarm, dry-run 0
setup "$D1" "$D1"; export WD_NOW_HOUR=10 WD_NOW_DOW=2 WD_NOW_WEEK=2026-39
assert_eq "0" "$(run)" "gesund → 0"; assert_eq "" "$(kinds)" "keine Alarme"
assert_eq "0" "$(run --dry-run)" "dry-run gesund → 0"

# 2. gestern + 15 Uhr → STALE; 10 Uhr → nicht
setup "$D0" "$D1"; WD_NOW_HOUR=15 run >/dev/null; assert_contains "STALE" "$(kinds)" "STALE ab 14 Uhr"
setup "$D0" "$D1"; WD_NOW_HOUR=10 run >/dev/null; assert_eq "" "$(kinds)" "vor 14 Uhr kein STALE"
setup "$D3" "$D1"; WD_NOW_HOUR=8 run >/dev/null; assert_contains "STALE" "$(kinds)" "3 Tage → STALE immer"
setup "$D3" "$D1"; assert_eq "1" "$(WD_NOW_HOUR=8 run --dry-run)" "dry-run mit Alarm → 1"

# 3. STALE unterdrückt, wenn Lauf aktiv oder Unit-Alarm < 24 h
setup "$D3" "$D1"; UNIT_ACTIVE=activating WD_NOW_HOUR=15 run >/dev/null; assert_eq "" "$(kinds)" "kein STALE während Lauf"
setup "$D3" "$D1"; printf 'GIVEUP\n%s\nx\n' "$(date -Is)" > "$STATE_DIR/last-alert"
WD_NOW_HOUR=15 run >/dev/null; assert_eq "" "$(kinds | grep -o STALE)" "kein STALE nach Unit-Alarm"

# 4. Token-Warnung ab 14 Tagen, einmal pro Tag
setup "$D1" "$(date -I -d "$D1 - 355 day")"; run >/dev/null; assert_contains "TOKEN" "$(kinds)" "TOKEN-Warnung"
n1=$(wc -l < "$STATE_DIR/alerts.log"); run >/dev/null; assert_eq "$n1" "$(wc -l < "$STATE_DIR/alerts.log")" "TOKEN nur einmal pro Tag"
setup "$D1" "$(date -I -d "$D1 - 300 day")"; run >/dev/null; assert_eq "" "$(kinds | grep -o TOKEN)" "kein TOKEN bei 65 Tagen Rest"

# 5. YouTube > 30 h
setup "$D1" "$D1" 40; run >/dev/null; assert_contains "YOUTUBE" "$(kinds)" "YOUTUBE alt"

# 6. Unit failed → FAILED einmal pro InvocationID
setup "$D1" "$D1"; UNIT_ACTIVE=failed UNIT_RESULT=exit-code UNIT_INV=inv1 run >/dev/null
assert_contains "FAILED" "$(kinds)" "FAILED"; n1=$(wc -l < "$STATE_DIR/alerts.log")
UNIT_ACTIVE=failed UNIT_RESULT=exit-code UNIT_INV=inv1 run >/dev/null; assert_eq "$n1" "$(wc -l < "$STATE_DIR/alerts.log")" "FAILED nicht doppelt"
UNIT_ACTIVE=failed UNIT_RESULT=exit-code UNIT_INV=inv2 run >/dev/null; assert_eq "$((n1+1))" "$(wc -l < "$STATE_DIR/alerts.log")" "neue InvocationID → erneut"

# 7. PUBLIC_STALE: Pages zeigt altes Datum, letzter Lauf > 60 min her
setup "$D1" "$D1"; PAGES_DATE="$D0" run >/dev/null; assert_contains "PUBLIC_STALE" "$(kinds)" "PUBLIC_STALE"
setup "$D1" "$D1"; touch "$STATE_DIR/last-run.json"; PAGES_DATE="$D0" run >/dev/null; assert_eq "" "$(kinds | grep -o PUBLIC)" "keine PUBLIC_STALE in der Gnadenfrist"

# 8. gh auth kaputt → GH_AUTH einmal pro Tag
setup "$D1" "$D1"; GH_AUTH_RC=1 run >/dev/null; assert_contains "GH_AUTH" "$(kinds)" "GH_AUTH"

# 9. Sonntag: Live-Check + Heartbeat einmal pro Woche; --resend wird aufgerufen
setup "$D1" "$D1"; WD_NOW_DOW=7 run >/dev/null
assert_contains "HEARTBEAT" "$(kinds)" "Heartbeat"; assert_contains -- "--max-turns" "$(cat "$STUB_BIN/claude.log")" "Live-Check lief"
n1=$(wc -l < "$STATE_DIR/alerts.log"); WD_NOW_DOW=7 run >/dev/null; assert_eq "$n1" "$(wc -l < "$STATE_DIR/alerts.log")" "Heartbeat nur einmal pro Woche"
setup "$D1" "$D1"; CLAUDE_LIVE_ERR=true WD_NOW_DOW=7 run >/dev/null; assert_contains "TOKEN_LIVE" "$(kinds)" "Live-Check-Fehler → TOKEN_LIVE"
setup "$D1" "$D1"; WD_NOW_DOW=7 run --dry-run >/dev/null; assert_eq "" "$(cat "$STUB_BIN/claude.log")" "dry-run ohne Live-Check"
test_summary
```

- [ ] **Step 2: Test laufen lassen, Fehlschlag sehen**

Run: `bash tests/test-watchdog.sh`
Expected: `FAIL`, `bin/watchdog.sh` fehlt.

- [ ] **Step 3: `bin/watchdog.sh` schreiben**

```bash
#!/usr/bin/env bash
#
# watchdog.sh — Prüfungen alle 30 min, nur Alarm, keine Reparatur (Spec 5.5).
#   --dry-run   alle Werte zeigen, nichts senden, keine Stempel; Exit 1 wenn ein Alarm anstünde
# Alarm-Arten: TOKEN, TOKEN_LIVE, STALE, PUBLIC_STALE, YOUTUBE, FAILED, GH_AUTH, HEARTBEAT
#
set -uo pipefail
LOG_TAG=watchdog
# shellcheck source=bin/lib-daily.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-daily.sh"
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALERT="$BIN/alert.sh"
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
load_env "$DAILY_ENV" || true
load_env "$ALERT_ENV" || true

TOKEN_WARN_DAYS="${TOKEN_WARN_DAYS:-14}"
STALE_HOUR="${STALE_HOUR:-14}"
YOUTUBE_MAX_H="${YOUTUBE_MAX_H:-30}"
PUBLIC_GRACE_MIN="${PUBLIC_GRACE_MIN:-60}"
UNIT=ai-news-dashboard-daily.service

NOW="$(date +%s)"; T="$(today)"
HOUR="${WD_NOW_HOUR:-$(date +%-H)}"; DOW="${WD_NOW_DOW:-$(date +%u)}"; WEEK="${WD_NOW_WEEK:-$(date +%G-%V)}"
WOULD=0

raise() {  # <ART> <Text> [--force]
  WOULD=1
  if [ "$DRY" = 1 ]; then log "[dry-run] ALARM [$1] $2"; return 0; fi
  "$ALERT" ${3:-} "$1" "$2" >/dev/null 2>&1 || true
}
once_per() {  # <stempel> <schlüssel> → 0 wenn für diesen Schlüssel noch nicht passiert
  [ "$(state_read "wd.$1")" = "$2" ] && return 1
  [ "$DRY" = 1 ] || state_write "wd.$1" "$2"
  return 0
}
unit_alert_recent() {  # <sekunden> → 0 wenn last-alert jünger und keine Watchdog-Art
  [ -f "$STATE_DIR/last-alert" ] || return 1
  [ $(( NOW - $(stat -c %Y "$STATE_DIR/last-alert") )) -lt "$1" ] || return 1
  case "$(sed -n 1p "$STATE_DIR/last-alert")" in STALE|PUBLIC_STALE|YOUTUBE|TOKEN*|GH_AUTH|HEARTBEAT|TEST) return 1 ;; esac
  return 0
}

# 0. pending nachsenden
[ "$DRY" = 1 ] || "$ALERT" --resend >/dev/null 2>&1 || true

# 1. Token-Restlaufzeit
TOKEN_DAYS=""
if [ -n "${TOKEN_CREATED:-}" ]; then
  TOKEN_DAYS=$(( 365 - $(days_between "$TOKEN_CREATED" "$T") ))
  log "Token: noch $TOKEN_DAYS Tage (erstellt $TOKEN_CREATED)"
  if [ "$TOKEN_DAYS" -le "$TOKEN_WARN_DAYS" ] && once_per token-warn "$T"; then
    raise TOKEN "Setup-Token läuft in $TOKEN_DAYS Tagen ab. Fix: 'claude setup-token' im Browser, dann bin/set-token.sh"
  fi
elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  warn "TOKEN_CREATED fehlt in daily.env — Ablaufwarnung unmöglich"
  once_per token-warn "$T" && raise TOKEN "TOKEN_CREATED fehlt in daily.env — bin/set-token.sh setzt es"
fi

# 2. Unit-Zustand
eval "$(systemctl show "$UNIT" -p ActiveState -p SubState -p Result -p InvocationID 2>/dev/null | sed 's/^/U_/')"
U_ActiveState="${U_ActiveState:-unknown}"; U_InvocationID="${U_InvocationID:-}"
RUNNING=0; case "$U_ActiveState" in active|activating) RUNNING=1 ;; esac
log "daily.service: $U_ActiveState/${U_SubState:-?} (Result=${U_Result:-?})"

# 3. Briefing lokal
CUR="$(snapshot_date "$PROJECT_DIR/dashboards/ai-news/index.html")"
AGE=999; [ -n "$CUR" ] && AGE="$(days_between "$CUR" "$T")"
LAST_RUN="$(python3 -c 'import json,sys
try: d=json.load(open(sys.argv[1])); print(f"{d.get(\"finished\",\"?\")} exit {d.get(\"exit\",\"?\")} {d.get(\"kind\",\"\")}: {str(d.get(\"text\",\"\"))[:80]}")
except Exception: print("kein last-run.json")' "$STATE_DIR/last-run.json" 2>/dev/null)"
log "Briefing vom ${CUR:-?} ($AGE Tage) · letzter Lauf: $LAST_RUN"
if [ "$RUNNING" = 1 ]; then
  log "Lauf aktiv — STALE-Prüfung ausgesetzt"
elif unit_alert_recent 86400; then
  log "Unit-Alarm < 24 h — STALE-Prüfung ausgesetzt"
elif { [ "$AGE" -ge 1 ] && [ "$HOUR" -ge "$STALE_HOUR" ]; } || [ "$AGE" -ge 2 ]; then
  raise STALE "Briefing vom ${CUR:-?} ist $AGE Tage alt. Letzter Lauf: $LAST_RUN · journalctl -u $UNIT"
fi

# 4. Briefing öffentlich (Pages)
PUB="$(curl -fsS -m 15 -H 'Cache-Control: no-cache' "$PAGES_URL" 2>/dev/null | grep -oE 'data-snapshot-date="[0-9-]{10}"' | head -1 | grep -oE '[0-9-]{10}' || true)"
log "Pages zeigt ${PUB:-nichts}"
if [ -n "$CUR" ] && [ "$PUB" != "$CUR" ] && [ -f "$STATE_DIR/last-run.json" ] \
   && [ $(( NOW - $(stat -c %Y "$STATE_DIR/last-run.json") )) -gt $(( PUBLIC_GRACE_MIN * 60 )) ]; then
  raise PUBLIC_STALE "Pages zeigt ${PUB:-nichts}, lokal $CUR. Pages-Build/Push prüfen: gh run list, git status -sb"
fi

# 5. YouTube
YT="$PROJECT_DIR/dashboards/youtube/data.json"
if [ -f "$YT" ]; then
  YT_H=$(( ( NOW - $(stat -c %Y "$YT") ) / 3600 )); log "youtube/data.json: ${YT_H} h alt"
  [ "$YT_H" -gt "$YOUTUBE_MAX_H" ] && raise YOUTUBE "youtube/data.json ist ${YT_H} h alt. journalctl -u ai-news-dashboard-youtube-fetch"
else
  raise YOUTUBE "youtube/data.json fehlt"
fi

# 6. Unit failed (Sicherheitsnetz, falls OnFailure nicht griff)
if [ "$U_ActiveState" = failed ] && [ -n "$U_InvocationID" ] && once_per failed-invocation "$U_InvocationID"; then
  unit_alert_recent 43200 || raise FAILED "daily.service ist failed (Result=${U_Result:-?}). journalctl -u $UNIT -n 30"
fi

# 7. GitHub-Auth
if ! gh auth status >/dev/null 2>&1; then
  once_per gh-auth "$T" && raise GH_AUTH "gh auth status schlägt fehl — Push würde scheitern. Fix: gh auth login"
fi

# 8. Sonntag: Live-Check + Lebenszeichen
LIVE="nicht geprüft"
if [ "$DOW" = 7 ] && once_per token-live "$WEEK"; then
  if [ "$DRY" = 1 ]; then LIVE="[dry-run] Live-Check übersprungen"
  elif CLAUDE_BIN="$(resolve_claude)"; then
    TMPD="$(mktemp -d)"
    if ( cd "$TMPD" && DISABLE_AUTOUPDATER=1 timeout 120 "$CLAUDE_BIN" -p 'Antworte nur mit OK' \
          --model "${CLAUDE_MODEL:-claude-opus-4-8}" --max-turns 1 --strict-mcp-config \
          --setting-sources project --output-format json </dev/null 2>/dev/null \
        | grep -q '"is_error": *false' ); then LIVE="ok"
    else LIVE="FEHLER"; raise TOKEN_LIVE "Wöchentlicher Live-Check mit dem Setup-Token schlug fehl. Token/Modell prüfen: bin/run-daily.sh --dry-run"; fi
    rm -rf "$TMPD"
  fi
fi
if [ "$DOW" = 7 ] && [ "${HEARTBEAT:-1}" = 1 ] && once_per heartbeat "$WEEK"; then
  WF="$(gh run list --workflow stale-check.yml --limit 1 --json conclusion,createdAt -q '.[0] | "\(.conclusion) \(.createdAt)"' 2>/dev/null || echo "unbekannt")"
  raise HEARTBEAT "lebt. Briefing $CUR, letzter Lauf: $LAST_RUN, Token noch ${TOKEN_DAYS:-?} Tage, Live-Check: $LIVE, GitHub-Wächter: $WF" --force
fi

[ "$DRY" = 1 ] && exit "$WOULD"
exit 0
```

- [ ] **Step 4: Tests laufen lassen**

Run: `bash -n bin/watchdog.sh && chmod +x bin/watchdog.sh && bash tests/test-watchdog.sh && bash tests/run-all.sh`
Expected: alle `ok`, `ALLE TESTS OK`.

- [ ] **Step 5: Dry-Run gegen die echte Maschine**

Run: `bin/watchdog.sh --dry-run; echo rc=$?`
Expected: Zeilen mit Token-Tagen (oder Warnung, dass `daily.env` fehlt), Unit-Zustand `unknown` (Unit noch nicht installiert), Briefing-Alter, Pages-Datum, YouTube-Alter; `rc=0`, solange das Briefing frisch ist.

- [ ] **Step 6: Commit**

```bash
git add bin/watchdog.sh tests/test-watchdog.sh
git commit -m "daily: watchdog.sh — Ergebnis-, Token-, Pages-, YouTube-Prüfung mit Alarmen

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: `bin/set-token.sh` und Env-Dateien

**Files:**
- Create: `bin/set-token.sh`
- Test: `tests/test-set-token.sh`
- Maschine (kein Repo): `~/.config/ai-news-dashboard/watchdog.env` → `alert.env` umbenennen

**Interfaces:**
- Consumes: `bin/lib-daily.sh` (`DAILY_ENV`, `env_file_valid`, `today`)
- Produces: `set-token.sh` liest den Token von stdin (nie als Argument), schreibt `CLAUDE_CODE_OAUTH_TOKEN` und `TOKEN_CREATED=<heute>` nach `$DAILY_ENV` (legt die Datei mit Defaults an, ersetzt vorhandene Zeilen), `chmod 600`, prüft das Format. Exit 0 ok · 2 Token-Format falsch · 3 Datei ungültig.

- [ ] **Step 1: Fehlschlagenden Test schreiben**

`tests/test-set-token.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
. tests/lib-test.sh; test_sandbox
export DAILY_ENV="$CONF_DIR/daily.env"
# neu anlegen
assert_rc 0 "neu" -- bash -c 'echo sk-ant-oat01-ABCdef_123-x | bin/set-token.sh'
assert_eq "600" "$(stat -c %a "$DAILY_ENV")" "Rechte 600"
assert_contains "CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-ABCdef_123-x" "$(cat "$DAILY_ENV")" "Token geschrieben"
assert_contains "TOKEN_CREATED=$(date -I)" "$(cat "$DAILY_ENV")" "TOKEN_CREATED heute"
assert_contains "CLAUDE_MODEL=claude-opus-4-8" "$(cat "$DAILY_ENV")" "Default-Modell"
# ersetzen, andere Zeilen bleiben
printf 'CLAUDE_MODEL=m2\nCLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-alt\nTOKEN_CREATED=2025-01-01\nMAX_BUDGET_USD=5\n' > "$DAILY_ENV"
echo sk-ant-oat01-neu | bin/set-token.sh >/dev/null
assert_eq "1" "$(grep -c '^CLAUDE_CODE_OAUTH_TOKEN=' "$DAILY_ENV")" "genau eine Token-Zeile"
assert_contains "CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-neu" "$(cat "$DAILY_ENV")" "Token ersetzt"
assert_contains "CLAUDE_MODEL=m2" "$(cat "$DAILY_ENV")" "andere Zeilen bleiben"
assert_contains "MAX_BUDGET_USD=5" "$(cat "$DAILY_ENV")" "Budget bleibt"
# falsches Format
assert_rc 2 "falsches Format" -- bash -c 'echo nicht-ein-token | bin/set-token.sh'
assert_rc 2 "leer" -- bash -c 'printf "" | bin/set-token.sh'
# Token taucht nicht in der Ausgabe auf
out="$(echo sk-ant-oat01-geheim | bin/set-token.sh 2>&1)"
assert_eq "" "$(grep -o geheim <<<"$out")" "Token nicht in Ausgabe"
test_summary
```

- [ ] **Step 2: Test laufen lassen, Fehlschlag sehen**

Run: `bash tests/test-set-token.sh` → `FAIL` (Skript fehlt).

- [ ] **Step 3: `bin/set-token.sh` schreiben**

```bash
#!/usr/bin/env bash
#
# set-token.sh — schreibt den langlebigen Token aus `claude setup-token` nach
# ~/.config/ai-news-dashboard/daily.env (Spec 5.6). Token kommt über stdin:
#   claude setup-token            # im Browser bestätigen, Token wird angezeigt
#   bin/set-token.sh              # Token einfügen, Enter, Ctrl-D
# Nie als Argument (landet sonst in Shell-History und ps).
# Exit: 0 ok · 2 Token-Format falsch · 3 Datei danach ungültig
#
set -uo pipefail
LOG_TAG=set-token
# shellcheck source=bin/lib-daily.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-daily.sh"

token="$(head -1 | tr -d '[:space:]')"
if ! [[ "$token" =~ ^sk-ant-oat01-[A-Za-z0-9_-]{20,}$ ]]; then
  warn "kein gültiger Setup-Token (erwartet sk-ant-oat01-…)"; exit 2
fi
mkdir -p "$(dirname "$DAILY_ENV")"; chmod 700 "$(dirname "$DAILY_ENV")" 2>/dev/null || true
if [ ! -f "$DAILY_ENV" ]; then
  printf 'CLAUDE_MODEL=claude-opus-4-8\nFALLBACK_MODEL=\nMAX_BUDGET_USD=30\n' > "$DAILY_ENV"
fi
tmp="$(mktemp "${DAILY_ENV}.XXXX")"
grep -vE '^(CLAUDE_CODE_OAUTH_TOKEN|TOKEN_CREATED)=' "$DAILY_ENV" > "$tmp"
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\nTOKEN_CREATED=%s\n' "$token" "$(today)" >> "$tmp"
mv "$tmp" "$DAILY_ENV"; chmod 600 "$DAILY_ENV"
if ! env_file_valid "$DAILY_ENV"; then warn "$DAILY_ENV ist nach dem Schreiben ungültig — Datei prüfen"; exit 3; fi
log "Token gespeichert in $DAILY_ENV (TOKEN_CREATED=$(today), Rechte 600)"
```

- [ ] **Step 4: Tests laufen lassen**

Run: `bash -n bin/set-token.sh && chmod +x bin/set-token.sh && bash tests/test-set-token.sh`
Expected: alle `ok`.

- [ ] **Step 5: Reale Env-Dateien auf der Maschine umstellen (kein Repo-Inhalt)**

```bash
mv ~/.config/ai-news-dashboard/watchdog.env ~/.config/ai-news-dashboard/alert.env
printf 'NTFY_TOPIC=\nHEALTHCHECKS_URL=\nHEARTBEAT=1\n' >> ~/.config/ai-news-dashboard/alert.env
chmod 600 ~/.config/ai-news-dashboard/alert.env
bash -c '. bin/lib-daily.sh; env_file_valid ~/.config/ai-news-dashboard/alert.env && echo "alert.env ok"'
ALERT_ENV=~/.config/ai-news-dashboard/alert.env bin/alert.sh --test
```
Expected: `alert.env ok`, Testnachricht kommt an. Hinweis: Der noch laufende alte Watchdog (`start-daily-loop.sh`) liest `watchdog.env` nur für optionale ntfy-Werte; nach der Umbenennung verliert er nichts Konfiguriertes.

- [ ] **Step 6: Commit**

```bash
git add bin/set-token.sh tests/test-set-token.sh
git commit -m "daily: set-token.sh — Setup-Token sicher nach daily.env schreiben

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: `DAILY_UPDATE.md` für den unbeaufsichtigten Oneshot

**Files:**
- Modify: `DAILY_UPDATE.md` (Zeilen 3–5 Einleitung; Sektion 0 Idempotenz; Sektion 4 Archivierung; Sektion 6 Verifikation; Sektion 8 Status; Schluss „Wenn du fertig bist")

**Interfaces:**
- Consumes: `bin/verify-briefing.sh --pre-deploy` (Task 3)
- Produces: die Zeile `STATUS: …` als Bilanz (Wrapper greppt `^STATUS:`), die Zeile `BLOCKED: <Grund>` bei Blockade (Wrapper → Exit 7)

- [ ] **Step 1: Einleitung ersetzen** (Zeilen 3–5)

Alt:
```
Dieses Dokument ist die Orchestrator-Anweisung für die Background-Session
`daily-ai-update`. Sie wird einmal täglich via `/loop 24h` ausgeführt und
durchläuft die Schritte unten.
```
Neu:
```
Dieses Dokument ist die Orchestrator-Anweisung für den täglichen Lauf des
ai-news-dashboards. Er wird von systemd um 07:15 als `claude -p`-Oneshot
gestartet (`bin/run-daily.sh`) und durchläuft die Schritte unten.

## Betriebsmodus: unbeaufsichtigt

- Es gibt niemanden, der Rückfragen beantwortet. Stelle keine Fragen und warte
  auf nichts; `AskUserQuestion` ist gesperrt.
- Entscheide konservativ selbst: lieber 3 statt 6 Breaking-News-Items, lieber ein
  kürzeres Briefing als Füllcontent, lieber eine Quelle weglassen als raten.
- Bei einer echten Blockade (z. B. `git push` wird abgelehnt, alle Quellen liefern
  dauerhaft Fehler): gib als **letzte Ausgabezeile** `BLOCKED: <Grund in einem
  Satz>` aus und höre auf. Der Wrapper wiederholt den Lauf später.
- Deine letzte Ausgabezeile im Erfolgsfall ist die `STATUS:`-Zeile aus Schritt 8.
```

- [ ] **Step 2: Idempotenz in Sektion 0 ersetzen**

Alt:
```
- **Idempotenz**: Prüfe `dashboards/ai-news/archive/<heute>.html`. Existiert
  die Datei bereits, wurde der Workflow heute schon ausgeführt — dann
  STOP und logge „Heute bereits aktualisiert" als Ergebnis.
```
Neu:
```
- **Idempotenz**: Lies `data-snapshot-date` aus dem `<body>`-Tag von
  `dashboards/ai-news/index.html`. Ist es bereits `<heute>`, wurde der Workflow
  heute schon ausgeführt — dann STOP mit der Ausgabe
  `STATUS: Heute bereits aktualisiert (<heute>)`. (Die frühere Prüfung auf
  `archive/<heute>.html` greift am selben Tag nie, weil heute erst morgen
  archiviert wird.)
```

- [ ] **Step 3: Sektion 4 idempotent machen** — nach dem bestehenden Punkt 6 anfügen:

```
7. **Idempotenz**: Existiert `archive/<gestern>.html` schon und hat das Manifest
   bereits einen Eintrag mit `url: /ai-news/archive/<gestern>.html`, überspringe
   die Punkte 3–5 für diesen Eintrag. Es darf nie zwei Manifest-Einträge mit
   demselben Datum und nie zwei Einträge mit `url: /ai-news/` geben.
```

- [ ] **Step 4: Sektion 6 Verifikation ersetzen** (den ganzen Codeblock und den Absatz „Wenn irgendwas fehlschlägt …")

Neu:
```
Nach allen Änderungen, vor dem Deploy:

```bash
bin/verify-briefing.sh --pre-deploy
```

Das Skript prüft Datum, Wortzahl, Breaking-Cards, Archiv des Vortags und das
Manifest und endet mit `RESULT: ok`. Bei `RESULT: quality: …` behebe den
genannten Punkt (z. B. Archivdatei nachziehen, Manifest-Duplikat entfernen) und
prüfe erneut. Bei `RESULT: not-deployed: …` stimmt das Snapshot-Datum nicht —
Schritt 5 wiederholen. Lässt sich ein Punkt nicht beheben: `BLOCKED: <Grund>`
ausgeben und aufhören.
```

- [ ] **Step 5: Sektion 8 Status ersetzen**

Alt (Codeblock + Absatz):
```
Lauf vom <heute>: <N> Breaking-News-Items, <M> Wörter Briefing, gestern
archiviert als <gestern>.html. YouTube refresh: <K> Videos. Claude Code:
v<latest> aktuell. Deploy: ✓
```
Neu:
```
STATUS: Lauf vom <heute>: <N> Breaking-News-Items, <M> Wörter Briefing, gestern
archiviert als <gestern>.html. YouTube refresh: <K> Videos. Claude Code:
v<latest> aktuell. Deploy: ✓ (<commit-hash>)
```
Absatz danach:
```
Diese Zeile muss mit `STATUS:` beginnen und die **letzte Ausgabezeile** sein
(ein Personen-Vorschlag aus Schritt 3 kommt davor). `bin/run-daily.sh` schreibt
sie ins Journal und nach `~/.local/state/ai-news-dashboard/last-run.json`;
`check.sh` zeigt sie an.
```

- [ ] **Step 6: Schluss ersetzen**

Alt:
```
## Wenn du fertig bist

`/loop` schläft automatisch für 24h. Du machst nichts weiter.
```
Neu:
```
## Wenn du fertig bist

Gib die `STATUS:`-Zeile aus und beende den Lauf. Der nächste Lauf startet
morgen 07:15 über den systemd-Timer; du planst nichts selbst (kein `/loop`,
kein Cron).
```

- [ ] **Step 7: Prüfen**

Run: `grep -nE '/loop|CronCreate' DAILY_UPDATE.md; grep -c '^STATUS:' DAILY_UPDATE.md; grep -n 'verify-briefing' DAILY_UPDATE.md`
Expected: keine `/loop`-Treffer; `STATUS:` einmal im Codeblock; `verify-briefing` in Sektion 6.

- [ ] **Step 8: Commit**

```bash
git add DAILY_UPDATE.md
git commit -m "prompt: Betriebsmodus unbeaufsichtigt, Idempotenz per Snapshot-Datum, STATUS-Marker, verify-briefing

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: `bin/deploy.sh` mit Pathspec und `restorecon -R`

**Files:**
- Modify: `bin/deploy.sh` (Zeilen 18–26 restorecon-Block, Zeile 34 `git add -A`)

**Interfaces:**
- Produces: `deploy.sh [msg]` committet nur `dashboards/` und `docs/`; Exit 0 auch, wenn nichts zu committen ist (unverändert).

- [ ] **Step 1: restorecon-Block ersetzen**

Alt (Zeilen 18–26):
```bash
if command -v restorecon >/dev/null 2>&1; then
  restorecon "$PROJECT_DIR/bin/start-daily-loop.sh" 2>/dev/null || true
fi
```
Neu:
```bash
# Alle bin/-Skripte tragen per semanage-Verzeichnisregel bin_t (Defense-in-Depth;
# die Units rufen /usr/bin/bash <skript>, sind also nicht auf das Label angewiesen).
if command -v restorecon >/dev/null 2>&1; then
  restorecon -R "$PROJECT_DIR/bin" 2>/dev/null || true
fi
```

- [ ] **Step 2: `git add -A` ersetzen** (Zeile 34)

Alt:
```bash
# 2. Stage everything (docs/ + any source changes)
git add -A
```
Neu:
```bash
# 2. Nur generierte Inhalte stagen. Infra-Änderungen (bin/, scripts/, *.md)
#    werden bewusst nicht mitgenommen: sie gehören in eigene Commits, und ein
#    manipulierter Lauf soll nichts Beliebiges ins öffentliche Repo schieben.
git add dashboards docs
```

- [ ] **Step 3: Prüfen**

Run: `bash -n bin/deploy.sh && touch notiz-test.txt && bin/deploy.sh "test: sollte notiz-test.txt nicht anfassen"; git status --short; rm notiz-test.txt`
Expected: Ausgabe `→ keine Änderungen, kein Commit` (oder ein Commit, der `notiz-test.txt` nicht enthält), `git status` zeigt `?? notiz-test.txt`.

- [ ] **Step 4: Commit**

```bash
git add bin/deploy.sh
git commit -m "deploy: nur dashboards/ und docs/ stagen, restorecon -R bin/

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: `install.sh` (neue Units, Reihenfolge, Env-Prüfung) und `bin/verify-daily.sh`

**Files:**
- Modify: `install.sh` (Kopfkommentar, Voraussetzungen, Abschnitt 3 Units, Abschnitt 4 Aktivierung, Abschluss-Hinweise)
- Create: `bin/verify-daily.sh`
- Delete: keine (alte Skripte erst in Task 14)

**Interfaces:**
- Consumes: `bin/lib-daily.sh` (`env_file_valid`), `~/.config/ai-news-dashboard/daily.env`, `alert.env`
- Produces: Units `ai-news-dashboard-daily.service/.timer`, `ai-news-dashboard-alert@.service`, `ai-news-dashboard-watchdog.service/.timer`, neu gerenderte `ai-news-dashboard-youtube-fetch.service`; entfernt `ai-news-dashboard-daily-loop.service`, `ai-news-dashboard-healthcheck.service/.timer`; SELinux-Regel `$PROJECT_DIR/bin(/.*)?` → `bin_t`.

- [ ] **Step 1: Kopfkommentar und Voraussetzungen anpassen**

Im Kopfkommentar `4. Webserver + YouTube-Timer + Daily-Loop aktivieren` → `4. Webserver + YouTube-Timer + Daily-Oneshot + Watchdog aktivieren`; Usage-Zeile `SKIP_DAILY_LOOP=1 ./install.sh # ohne Claude Background-Session` → `SKIP_DAILY=1 ./install.sh      # ohne Daily-Oneshot/Watchdog`. Variable `SKIP_DAILY_LOOP` überall durch `SKIP_DAILY` ersetzen (`grep -n SKIP_DAILY_LOOP install.sh`).

Nach dem `claude`-Check in Abschnitt 1 einfügen:

```bash
# Env-Dateien (Secrets) müssen VOR der Installation existieren und gültig sein
CONF_DIR="$HOME/.config/ai-news-dashboard"
if [ "$SKIP_DAILY" != "1" ]; then
  # shellcheck source=bin/lib-daily.sh
  . "$PROJECT_DIR/bin/lib-daily.sh"
  for f in daily.env alert.env; do
    if ! env_file_valid "$CONF_DIR/$f"; then
      red "✗"; echo " $CONF_DIR/$f fehlt oder ist ungültig (KEY=wert, Kommentare nur als ganze Zeilen)"
      echo "    daily.env: claude setup-token → bin/set-token.sh · alert.env: CALLMEBOT_PHONE/CALLMEBOT_APIKEY"
      exit 1
    fi
  done
  grep -q '^CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-' "$CONF_DIR/daily.env" || { red "✗"; echo " kein Setup-Token in daily.env — bin/set-token.sh"; exit 1; }
  green "✓"; echo " daily.env + alert.env vorhanden und gültig"
  sudo -v   # ein Passwort-Prompt, Timestamp für alle folgenden sudo-Aufrufe
fi
```

- [ ] **Step 2: Unit-Vorlagen ersetzen** — in Abschnitt 3 den Block von `# Daily loop (Claude background session orchestrator)` bis zum schließenden `fi` der Healthcheck-Timer-Vorlage durch Folgendes ersetzen. Die YouTube-Vorlage darüber wird ebenfalls geändert (siehe Step 3).

```bash
# Daily-Oneshot (claude -p) + Alert-Template + Watchdog
if [ "$SKIP_DAILY" != "1" ]; then
cat > "$TMP/ai-news-dashboard-daily.service" <<EOF
[Unit]
Description=Daily AI news briefing (claude -p oneshot)
Documentation=file://$PROJECT_DIR/specs/2026-09-24-daily-run-oneshot-design.md
After=network-online.target ai-news-dashboard-youtube-fetch.service
Wants=network-online.target
OnFailure=ai-news-dashboard-alert@%p.service
StartLimitIntervalSec=12h
StartLimitBurst=3

[Service]
Type=oneshot
User=$RUN_USER
Group=$RUN_GROUP
WorkingDirectory=$PROJECT_DIR
Environment=DISABLE_AUTOUPDATER=1 GIT_TERMINAL_PROMPT=0 GH_NO_UPDATE_NOTIFIER=1
StandardInput=null
ExecStart=/usr/bin/bash $PROJECT_DIR/bin/run-daily.sh
TimeoutStartSec=90min
TimeoutStopSec=3min
Restart=on-failure
RestartSec=2h
RestartPreventExitStatus=3 4 8 9 10 11
InaccessiblePaths=-$HOME/.ssh
EOF

cat > "$TMP/ai-news-dashboard-daily.timer" <<EOF
[Unit]
Description=Daily AI news briefing at 07:15

[Timer]
OnCalendar=*-*-* 07:15:00
Persistent=true
Unit=ai-news-dashboard-daily.service

[Install]
WantedBy=timers.target
EOF

cat > "$TMP/ai-news-dashboard-alert@.service" <<EOF
[Unit]
Description=Alert for failed unit %i (CallMeBot/ntfy/journal)

[Service]
Type=oneshot
User=$RUN_USER
Group=$RUN_GROUP
WorkingDirectory=$PROJECT_DIR
StandardInput=null
TimeoutStartSec=2min
ExecStart=/usr/bin/bash $PROJECT_DIR/bin/alert.sh unit-failed %i
EOF

cat > "$TMP/ai-news-dashboard-watchdog.service" <<EOF
[Unit]
Description=Watchdog: briefing freshness, token, pages, youtube (alerts only)
OnFailure=ai-news-dashboard-alert@%p.service

[Service]
Type=oneshot
User=$RUN_USER
Group=$RUN_GROUP
WorkingDirectory=$PROJECT_DIR
Environment=DISABLE_AUTOUPDATER=1 GH_NO_UPDATE_NOTIFIER=1
StandardInput=null
TimeoutStartSec=5min
ExecStart=/usr/bin/bash $PROJECT_DIR/bin/watchdog.sh
EOF

cat > "$TMP/ai-news-dashboard-watchdog.timer" <<EOF
[Unit]
Description=Watchdog every 30 minutes

[Timer]
OnCalendar=*-*-* *:00/30:00
Unit=ai-news-dashboard-watchdog.service

[Install]
WantedBy=timers.target
EOF
fi
```

- [ ] **Step 3: YouTube-Vorlage anpassen** (in `cat > "$TMP/ai-news-dashboard-youtube-fetch.service"`):
  - nach `ExecStart=…` die Zeilen
    ```
    ExecStartPost=/usr/bin/bash $PROJECT_DIR/bin/deploy.sh
    TimeoutStartSec=10min
    Environment=GIT_TERMINAL_PROMPT=0 GH_NO_UPDATE_NOTIFIER=1
    ```
    (die bisherige `ExecStartPost=$PROJECT_DIR/bin/deploy.sh` ersetzen)
  - `ReadWritePaths=$PROJECT_DIR` bleibt; zusätzlich `ReadWritePaths=$HOME/.config/gh` anhängen (gh schreibt beim Push ggf. `state.yml`; unter `ProtectHome=read-only` wäre das sonst EROFS).

- [ ] **Step 4: Installations-Reihenfolge** — den Block `echo "  Installiere Units nach /etc/systemd/system/ (sudo)"` … `green "✓"; echo " Units installiert + systemd reloaded"` ersetzen durch:

```bash
if [ "$SKIP_DAILY" != "1" ]; then
  echo "  Alte Session-Units entfernen"
  for u in ai-news-dashboard-daily-loop.service ai-news-dashboard-healthcheck.timer ai-news-dashboard-healthcheck.service; do
    sudo systemctl disable --now "$u" 2>/dev/null || true
    sudo systemctl reset-failed "$u" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/$u"
  done
  echo "  SELinux: bin/ als bin_t (Defense-in-Depth)"
  if command -v semanage >/dev/null 2>&1; then
    sudo semanage fcontext -a -t bin_t "$PROJECT_DIR/bin(/.*)?" 2>/dev/null \
      || sudo semanage fcontext -m -t bin_t "$PROJECT_DIR/bin(/.*)?"
    sudo restorecon -R "$PROJECT_DIR/bin"
  fi
fi
echo "  Units prüfen (systemd-analyze verify)"
systemd-analyze verify "$TMP"/*.service "$TMP"/*.timer 2>&1 | grep -v "KillMode=none" || true
echo "  Installiere Units nach /etc/systemd/system/ (sudo)"
sudo install -m 644 "$TMP"/*.service "$TMP"/*.timer /etc/systemd/system/
sudo systemctl daemon-reload
green "✓"; echo " Units installiert + systemd reloaded"
```

- [ ] **Step 5: Aktivierung** — in Abschnitt 4 den `if [ "$SKIP_DAILY_LOOP" != "1" ]; then … fi`-Block ersetzen:

```bash
if [ "$SKIP_DAILY" != "1" ]; then
  sudo systemctl enable --now ai-news-dashboard-daily.timer
  green "✓"; echo " daily.timer aktiv (07:15, Persistent)"
  sudo systemctl enable --now ai-news-dashboard-watchdog.timer
  green "✓"; echo " watchdog.timer aktiv (alle 30 Min)"
  systemctl list-timers ai-news-dashboard-* --no-pager | sed 's/^/    /'
fi
```
Und im Abschluss-Text die Zeile mit `start-daily-loop.sh` durch
`$([ "$SKIP_DAILY" != "1" ] && echo "    ./bin/verify-daily.sh        # Oneshot + Watchdog einmal per systemd auslösen")` ersetzen.

- [ ] **Step 6: `bin/verify-daily.sh` schreiben**

```bash
#!/usr/bin/env bash
#
# verify-daily.sh — löst daily.service und watchdog.service einmal per systemd aus
# und prüft, dass systemd die Skripte ausführen KANN (Exec, Env, Pfade).
# daily.service ist idempotent: steht das heutige Briefing schon, endet er mit 0.
# Danach werden Startlimit und Tageszähler zurückgesetzt, damit Tests keine
# echten Versuche kosten. Braucht sudo für `systemctl start`/`reset-failed`.
#
set -uo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
for unit in ai-news-dashboard-daily.service ai-news-dashboard-watchdog.service; do
  echo "== $unit"
  sudo systemctl start "$unit" || true
  result="$(systemctl show "$unit" -p Result --value)"
  code="$(systemctl show "$unit" -p ExecMainStatus --value)"
  printf "   Result=%s ExecMainStatus=%s\n" "$result" "$code"
  journalctl -u "$unit" -n 8 --no-pager -o cat | sed 's/^/   | /'
  case "$code" in
    0) ;;
    203|126|127) fail=1; echo "   ✗ Exec-Problem (203 SELinux/Pfad, 126/127 Binary)" ;;
    *) echo "   ⚠ Skript lief, endete mit $code — Grund siehe Journal (kein Exec-Problem)" ;;
  esac
done
sudo systemctl reset-failed ai-news-dashboard-daily.service 2>/dev/null || true
"$PROJECT_DIR/bin/run-daily.sh" --reset-attempts
if [ "$fail" -eq 0 ]; then echo "✓ PASS — systemd kann Oneshot und Watchdog ausführen"; else echo "✗ FAIL"; exit 1; fi
```

- [ ] **Step 7: Prüfen ohne sudo**

Run: `bash -n install.sh bin/verify-daily.sh && grep -n "SKIP_DAILY_LOOP\|start-daily-loop\|healthcheck" install.sh`
Expected: keine Treffer außer den Zeilen, die die alten Units entfernen. Zusätzlich die gerenderten Units trocken prüfen:
```bash
TMP=$(mktemp -d); PROJECT_DIR=$PWD RUN_USER=$USER RUN_GROUP=$(id -gn) HOME=$HOME bash -c "$(sed -n '/^# Daily-Oneshot/,/^fi$/p' install.sh)"; systemd-analyze verify "$TMP"/*.service "$TMP"/*.timer; ls "$TMP"
```
Expected: `systemd-analyze verify` ohne Fehlerzeilen; fünf Dateien im Temp-Verzeichnis.

- [ ] **Step 8: Commit**

```bash
git add install.sh bin/verify-daily.sh
git commit -m "install: Daily-Oneshot, Alert-Template, Watchdog-Units; alte Session-Units entfernen; SELinux-Verzeichnisregel

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 11: `.github/workflows/stale-check.yml` (externer Wächter)

**Files:**
- Create: `.github/workflows/stale-check.yml`

**Interfaces:**
- Produces: täglicher GitHub-Actions-Lauf (16:17 UTC), der fehlschlägt, wenn das Pages-Briefing älter als der Vortag ist; `workflow_dispatch` mit Eingabe `force_fail` zum Test. Fehler-Mails gehen an den Actor des Schedule-Laufs = letzter Committer der Workflow-Datei.

- [ ] **Step 1: Workflow schreiben**

```yaml
name: stale-check
# Externer Wächter (Spec 5.11): läuft unabhängig von der Maschine. Schlägt fehl,
# wenn das öffentliche Briefing älter als der Vortag ist → GitHub mailt den Actor
# (letzter Committer dieser Datei). Kein Secret, kein Schreibzugriff.
on:
  schedule:
    - cron: '17 16 * * *'   # krumme Minute: volle Stunden werden von GitHub oft verzögert/übersprungen
  workflow_dispatch:
    inputs:
      force_fail:
        description: 'Zum Test absichtlich fehlschlagen (true/false)'
        default: 'false'
permissions:
  contents: read
jobs:
  check:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - name: Briefing-Datum auf GitHub Pages prüfen
        env:
          URL: https://szymansk.github.io/agentic-info-dashboard/ai-news/
          FORCE_FAIL: ${{ github.event.inputs.force_fail }}
        run: |
          set -euo pipefail
          html="$(curl -fsSL -H 'Cache-Control: no-cache' --max-time 30 "$URL")"
          date="$(grep -oE 'data-snapshot-date="[0-9]{4}-[0-9]{2}-[0-9]{2}"' <<<"$html" | head -1 | grep -oE '[0-9-]{10}' || true)"
          today="$(date -u +%F)"; yesterday="$(date -u -d 'yesterday' +%F)"
          echo "Pages: ${date:-kein Datum gefunden} · heute (UTC): $today · Toleranz bis: $yesterday"
          if [ "$FORCE_FAIL" = "true" ]; then echo "::error::Testlauf: absichtlicher Fehlschlag"; exit 1; fi
          if [ -z "$date" ]; then echo "::error::kein data-snapshot-date auf $URL"; exit 1; fi
          if [[ "$date" < "$yesterday" ]]; then
            echo "::error::Briefing ist vom $date — älter als $yesterday. Der Tageslauf auf der Maschine steht."
            exit 1
          fi
          echo "ok — Briefing vom $date"
```

- [ ] **Step 2: Lokal prüfen**

Run: `python3 -c "import yaml" 2>/dev/null && python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/stale-check.yml')); print('YAML ok')" || echo "(kein PyYAML — Einrückung von Hand prüfen)"`; zusätzlich den `run:`-Block manuell ausführen: `URL=https://szymansk.github.io/agentic-info-dashboard/ai-news/ FORCE_FAIL=false bash -c '<Block>'` → `ok — Briefing vom <heute>`.

- [ ] **Step 3: Commit** (der Committer dieser Datei ist der Actor der Schedule-Läufe — Marc)

```bash
git add .github/workflows/stale-check.yml
git commit -m "ci: stale-check — externer Wächter für das Pages-Briefing (täglich 16:17 UTC)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

Hinweis für Phase 3f (Task 14): Marc muss in GitHub → Settings → Notifications unter „Actions" die E-Mail für „Failed workflows only" aktiviert haben.

---

### Task 12: `bin/check.sh` — Sektion „daily run"

**Files:**
- Modify: `bin/check.sh` (Unit-Liste in „systemd units"; Sektion `hdr "background sessions (Claude daily loop)"` bis vor `hdr "summary"` ersetzen)

**Interfaces:**
- Consumes: `bin/watchdog.sh --dry-run` (Exit 0/1), `bin/run-daily.sh --dry-run` (Exit 0/3/4/9), `$STATE_DIR/last-run.json`, `last-alert`, `systemctl show/list-timers`

- [ ] **Step 1: Unit-Liste anpassen** — in der `for unit in …`-Schleife `ai-news-dashboard-daily-loop.service` durch `ai-news-dashboard-daily.timer ai-news-dashboard-watchdog.timer` ersetzen und den `failed)`-Zweig für `daily-loop` entfernen (Timer sind `active`; `.timer` fällt in den bestehenden `*.timer`-Zweig).

- [ ] **Step 2: Sektion ersetzen** (alles von `hdr "background sessions (Claude daily loop)"` bis vor `hdr "summary"`):

```bash
hdr "daily run (claude -p oneshot)"
STATE_DIR="${STATE_DIR:-$HOME/.local/state/ai-news-dashboard}"
if [ -f "$STATE_DIR/last-run.json" ]; then
  python3 - "$STATE_DIR/last-run.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"  · letzter Lauf: {d.get('finished','?')} · Exit {d.get('exit','?')} ({d.get('kind','')}) · {d.get('duration_s','?')} s · {d.get('total_cost_usd') or '?'} USD · {d.get('num_turns') or '?'} Turns · CLI {d.get('claude_version','?')}")
print(f"  · {d.get('status') or d.get('text','')}")
PY
  [ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["exit"])' "$STATE_DIR/last-run.json")" = 0 ] \
    && ok "letzter Lauf erfolgreich" || err "letzter Lauf gescheitert — journalctl -u ai-news-dashboard-daily -n 40"
else
  warn "noch kein last-run.json (kein Oneshot-Lauf bisher)"
fi
d_state="$(systemctl show ai-news-dashboard-daily.service -p ActiveState -p SubState --value 2>/dev/null | tr '\n' '/')"
d_next="$(systemctl show ai-news-dashboard-daily.timer -p NextElapseUSecRealtime --value 2>/dev/null)"
case "$d_state" in
  activating/auto-restart/) warn "daily.service wartet auf Retry (auto-restart) · nächster Timer: ${d_next:-?}" ;;
  active/*|activating/start/) ok "daily.service läuft gerade" ;;
  failed/*) err "daily.service failed — Alarm sollte gekommen sein; journalctl -u ai-news-dashboard-daily -n 40" ;;
  *) ok "daily.service ${d_state:-unbekannt} · nächster Timer: ${d_next:-?}" ;;
esac
w_res="$(systemctl show ai-news-dashboard-watchdog.service -p Result -p ExecMainStatus --value 2>/dev/null | tr '\n' ' ')"
[ "${w_res% }" = "success 0" ] && ok "watchdog.service letzter Lauf ok" || warn "watchdog.service: ${w_res:-nie gelaufen} — journalctl -u ai-news-dashboard-watchdog -n 20"

# Preflight des Tageslaufs (Token, Tree, Repo) und Watchdog-Sicht — beides ohne Nebenwirkung
pre="$("$PROJECT_DIR/bin/run-daily.sh" --dry-run 2>&1 </dev/null)"; pre_rc=$?
printf '%s\n' "$pre" | sed 's/^  \[daily\] /    /'
case "$pre_rc" in 0) ok "Preflight ok" ;; *) err "Preflight scheitert (Exit $pre_rc) — siehe oben" ;; esac
wd="$("$PROJECT_DIR/bin/watchdog.sh" --dry-run 2>&1)"; wd_rc=$?
printf '%s\n' "$wd" | sed 's/^  \[watchdog\] /    /'
case "$wd_rc" in 0) ok "Watchdog: nichts zu melden" ;; *) warn "Watchdog würde alarmieren — siehe oben" ;; esac
if [ -f "$STATE_DIR/last-alert" ]; then
  err "letzter Alarm [$(sed -n 1p "$STATE_DIR/last-alert")] $(sed -n 2p "$STATE_DIR/last-alert"): $(sed -n 3p "$STATE_DIR/last-alert")"
fi
if [ -d "$STATE_DIR/pending" ] && [ -n "$(ls -A "$STATE_DIR/pending" 2>/dev/null)" ]; then
  warn "unzugestellte Alarme in $STATE_DIR/pending"
fi
if ! grep -qs '^HEALTHCHECKS_URL=.\+' "$HOME/.config/ai-news-dashboard/alert.env" 2>/dev/null; then
  warn "kein healthchecks.io konfiguriert — externer Wächter ist nur der GitHub-Workflow (gh run list --workflow stale-check.yml)"
fi

```

- [ ] **Step 3: Prüfen**

Run: `bash -n bin/check.sh && ./bin/check.sh`
Expected: Sektion „daily run" erscheint; vor der Installation der Units sind `daily.service unbekannt` und `watchdog.service nie gelaufen` gelb, Preflight meldet den Token-Stand. Keine Zeile darf `background sessions` oder `start-daily-loop` mehr enthalten.

- [ ] **Step 4: Commit**

```bash
git add bin/check.sh
git commit -m "check: Sektion daily run (letzter Lauf, Unit-Zustand, Preflight, Watchdog, Alarme)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 13: Dokumentation (`CLAUDE.md`, Memory)

**Files:**
- Modify: `CLAUDE.md` (Architektur-Baum, Tabelle „Update-Verantwortlichkeiten", Tabelle „Systemd-Units", Abschnitt „Background-Session-Mechanik" samt der vier Failure-Modes, „Was ich NICHT tun soll", „Wo finde ich was")
- Modify: Memory `project_auth_expiry_watchdog.md` (Hinweis auf Ablösung), `MEMORY.md` (Zeile ergänzen)

- [ ] **Step 1: Architektur-Baum** — im Baum `DAILY_UPDATE.md` beschreiben als `# Prompt für den täglichen claude -p-Oneshot`; unter `bin/` die Zeilen für `start-daily-loop.sh` und `loop.sh` durch
```
│   ├── run-daily.sh            # Tageslauf: claude -p + Klassifikation + Verify + Cleanup
│   ├── verify-briefing.sh      # Ergebnisprüfung (--pre-deploy im Prompt, --full im Wrapper)
│   ├── alert.sh                # einziger Alarmweg (CallMeBot/ntfy/Journal)
│   ├── watchdog.sh             # alle 30 min: Frische, Token, Pages, YouTube
│   ├── set-token.sh            # Setup-Token nach ~/.config/ai-news-dashboard/daily.env
│   ├── verify-daily.sh         # Units einmal per systemd auslösen
```
ersetzen; `specs/` und `plans/` als Zeilen ergänzen (`# Design-Specs` / `# Implementierungspläne`); `.github/workflows/stale-check.yml # externer Wächter (Pages-Datum)`.

- [ ] **Step 2: Tabellen** — „Update-Verantwortlichkeiten": Zeile `/ai-news/` → `systemd-Timer 07:15 → bin/run-daily.sh → claude -p (DAILY_UPDATE.md)` · `täglich`. „Systemd-Units": die Zeile `ai-news-dashboard-daily-loop.service` ersetzen durch

```
| `ai-news-dashboard-daily.timer/.service` | timer → oneshot | täglich 07:15, Retry 2 h, max. 3/Tag |
| `ai-news-dashboard-alert@.service` | oneshot (Template) | von `OnFailure` der Units |
| `ai-news-dashboard-watchdog.timer/.service` | timer → oneshot | alle 30 min, nur Alarme |
```

- [ ] **Step 3: Abschnitt „Background-Session-Mechanik" ersetzen** — der gesamte Abschnitt (bis vor „## Was ich (Claude) hier NICHT tun soll") wird zu:

```markdown
## Tageslauf-Mechanik (seit 2026-09, systemd-Oneshot)

`ai-news-dashboard-daily.timer` startet 07:15 `bin/run-daily.sh`, das `claude -p`
mit `DAILY_UPDATE.md` ausführt (Token aus `~/.config/ai-news-dashboard/daily.env`,
nur in dieser Prozessumgebung). Design und Begründung: `specs/2026-09-24-daily-run-oneshot-design.md`.

**Runbook**
- Zustand: `./bin/check.sh` (Sektion „daily run"), `journalctl -u ai-news-dashboard-daily -n 40`,
  `journalctl -t ai-news-alert`, `~/.local/state/ai-news-dashboard/last-run.json`
- Lauf von Hand: `sudo systemctl start ai-news-dashboard-daily.service` (idempotent: steht das
  heutige Briefing schon, Exit 0). Danach `sudo systemctl reset-failed …` + `bin/run-daily.sh --reset-attempts`,
  sonst zählen Handstarts als Versuche.
- Alarm `AUTH`/`TOKEN`/`TOKEN_LIVE`: `claude setup-token` im Browser → `bin/set-token.sh` (Token per stdin).
- Alarm `DIRTY`: fremde Änderungen im Working Tree committen oder stashen; der Lauf fasst nur
  `dashboards/ai-news`, `dashboards/it-services`, `docs` an.
- Alarm `GIVEUP`/`STUCK`-artige Fälle: Grund steht in der Nachricht und in `last-failure.daily`;
  Transcript des Laufs: `~/.claude/projects/<slug>/<session_id>.jsonl` (`session_id` in `last-run.json`).
- Alarm `REPO`: `git status -sb`, `git log --oneline -3 origin/main` — von Hand rebasen/pushen.
- Alarm `QUALITY`: Briefing ist deployt, aber dünn/kaputt (Grund in der Nachricht); Schwellen in
  `daily.env` (`MIN_WORDS`, `MIN_CARDS`), Prüfung selbst: `bin/verify-briefing.sh --full`.
- Alarm `PUBLIC_STALE`: Pages hinkt — `gh run list`, GitHub-Pages-Status; lokal ist alles ok.
- Kein Alarm, aber Briefing alt: GitHub-Workflow `stale-check` mailt spätestens 18:17 CEST;
  `gh run list --workflow stale-check.yml`.
- Testkette (nach Änderungen an Units/Skripten): `bash tests/run-all.sh`, `./bin/verify-daily.sh`,
  `bin/alert.sh --test`.

**Historie (Background-Session, Mai–September 2026)**: Vier stille Ausfälle (Upgrade-Kill
29.05., Idle-Exit + Modell 15.06., SELinux + PATH 01.07., Auth-Ablauf + blinder Selbstheiler
11.07.–24.09.) führten zur Ablösung. Details und Lehren: Spec Abschnitt 2 und
`git log -- bin/start-daily-loop.sh`.
```

- [ ] **Step 4: „Was ich NICHT tun soll"** — ergänzen: `- \`~/.config/ai-news-dashboard/*.env\` ins Repo oder in Logs bringen (Secrets)` und `- \`ai-news-dashboard-daily.service\` von Hand starten, ohne danach \`reset-failed\` + \`--reset-attempts\``. Entfernen: die Zeile über `grep -q` unter pipefail bleibt (gilt weiter).

- [ ] **Step 5: „Wo finde ich was"** — `Watchdog-Alarme` → `journalctl -t ai-news-alert`, `~/.local/state/ai-news-dashboard/{alerts.log,last-alert,last-run.json}`; neue Zeile `- **Tageslauf-Transcript**: \`~/.claude/projects/-home-szymansk-Projects-agentic-info-dashboard/<session_id>.jsonl\``.

- [ ] **Step 6: Memory** — in `~/.claude/projects/-home-szymansk-Projects-agentic-info-dashboard/memory/project_auth_expiry_watchdog.md` unter „How to apply" die erste Zeile ersetzen durch `- Seit <Datum von Task 14> abgelöst: Tageslauf ist systemd-Oneshot (\`bin/run-daily.sh\`), Diagnose mit \`./bin/check.sh\` Sektion „daily run".`; in `MEMORY.md` die Zeile dieses Eintrags entsprechend kürzen. Kein neuer Memory-Eintrag nötig: CLAUDE.md und Spec tragen das Wissen.

- [ ] **Step 7: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(claude): Tageslauf-Mechanik (Oneshot) + Runbook, Session-Ära als Historie

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 14: Migration (Phasen 0, 2, 3) und Rückbau (Phase 4)

**Files:**
- Delete (erst Phase 4): `bin/start-daily-loop.sh`, `bin/loop.sh`, `bin/verify-daily-loop.sh`, `bin/fix-selinux-launcher.sh`
- Maschine: `~/.config/ai-news-dashboard/daily.env` (Phase 0), Units (Phase 2)

**Interfaces:**
- Consumes: alles aus Tasks 1–13, committet. Voraussetzung: `bash tests/run-all.sh` grün, `git status` clean.
- Wer: „Marc" = braucht Browser, Handy oder sudo; „Claude" = ohne Rechte.

- [ ] **Phase 0 (Marc): Token und Wächter vorbereiten**

```bash
claude setup-token           # Browser öffnet sich; den angezeigten Token kopieren
bin/set-token.sh             # Token einfügen, Enter, Ctrl-D → "Token gespeichert …"
DAILY_ENV=~/.config/ai-news-dashboard/daily.env bin/run-daily.sh --dry-run </dev/null
```
Expected: letzte Zeile `Briefing vom <heute> ist gepusht — nichts zu tun` oder `würde claude -p starten`, Exit 0. Optional healthchecks.io: Check anlegen (Period 1 day, Grace 30 h), Ping-URL als `HEALTHCHECKS_URL=` in `alert.env`. GitHub: Settings → Notifications → Actions → „Failed workflows only" aktiv.

- [ ] **Phase 2 (Marc + Claude): Umschalten**

```bash
sudo ./install.sh                       # ein Passwort-Prompt; entfernt alte Units, installiert neue, aktiviert Timer
bin/alert.sh --test                     # WhatsApp muss ankommen
./bin/loop.sh attach                    # alte Session: /cron list → Cron-Eintrag löschen → ← zum Detachen
./bin/loop.sh stop                      # alte Session beenden (der alte Selbstheiler ist mit install.sh weg)
systemctl list-timers ai-news-dashboard-* --no-pager
./bin/check.sh
```
Expected: `daily.timer` und `watchdog.timer` aktiv mit nächsten Zeitpunkten; `healthcheck.timer` und `daily-loop.service` nicht mehr gelistet; `loop.sh status` meldet keine Session; `check.sh` zeigt Preflight ok. Die alten Skripte bleiben bis Phase 4 als manueller Notfallweg (`./bin/start-daily-loop.sh --force` würde die Session-Mechanik wieder starten).

- [ ] **Phase 3a (Marc): idempotenter Start**

```bash
./bin/verify-daily.sh
```
Expected: `daily.service` → `Result=success ExecMainStatus=0`, Journal enthält `Briefing vom <heute> ist gepusht — nichts zu tun`; `watchdog.service` → `0`; `✓ PASS`.

- [ ] **Phase 3b (Marc): Ende-zu-Ende-Alarmtest über die echte Kette**

```bash
printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-absichtlich-ungueltig-0000000000\n' > /tmp/daily-test.env; chmod 600 /tmp/daily-test.env
sudo systemctl edit --runtime ai-news-dashboard-daily.service
#   [Service]
#   Environment=DAILY_ENV=/tmp/daily-test.env
sudo systemctl start ai-news-dashboard-daily.service; sleep 20
systemctl show ai-news-dashboard-daily.service -p Result -p ExecMainStatus
journalctl -u ai-news-dashboard-alert@ai-news-dashboard-daily.service -n 5 --no-pager
```
Expected: `Result=exit-code ExecMainStatus=3`, Alert-Unit lief, WhatsApp „⛔ ai-news [AUTH] daily: api 401 …" kommt an. Aufräumen:
```bash
sudo systemctl revert ai-news-dashboard-daily.service; sudo systemctl daemon-reload
sudo systemctl reset-failed ai-news-dashboard-daily.service; bin/run-daily.sh --reset-attempts
rm /tmp/daily-test.env; rm -f ~/.local/state/ai-news-dashboard/last-failure.daily
```

- [ ] **Phase 3c (Claude): `--setting-sources project` vor dem ersten Echtlauf testen**

```bash
set -a; . ~/.config/ai-news-dashboard/daily.env; set +a
cd "$(mktemp -d)" && timeout 120 claude -p 'Antworte nur mit OK' --model "$CLAUDE_MODEL" --max-turns 1 \
  --strict-mcp-config --setting-sources project --dangerously-skip-permissions --output-format json </dev/null \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("is_error"), d.get("result"))'
```
Expected: `False OK`. Dann `CLAUDE_SETTING_SOURCES=project` in `daily.env` eintragen (sonst erbt der Lauf User-Plugins/Hooks). Schlägt es fehl (Permission-Prompt, Fehler), Zeile weglassen und in der Spec §9 vermerken.

- [ ] **Phase 3d (beide): erster Echtlauf am Folgetag**

```bash
journalctl -u ai-news-dashboard-daily -f          # ab 07:14
```
Expected: `starte claude -p`, nach 5–20 min `RESULT: ok`, `STATUS: Lauf vom …`, `Pages zeigt <heute>`, Exit 0; `check.sh` grün; Kosten in `last-run.json` notieren und `MAX_BUDGET_USD` bei Bedarf anpassen (mindestens 3× Ist).

- [ ] **Phase 3e (beide): YouTube-Deploy aus der gehärteten Unit**

Am selben Morgen: `journalctl -u ai-news-dashboard-youtube-fetch --since 05:55 --no-pager` → `deploy.sh` lief, `→ pushed to origin/main` oder `keine Änderungen`; kein `EROFS`/`Permission denied`. Bei `gh`-Schreibfehlern `ReadWritePaths` in `install.sh` ergänzen und neu installieren.

- [ ] **Phase 3f (Marc): GitHub-Wächter Ende-zu-Ende**

```bash
gh workflow run stale-check.yml -f force_fail=true; sleep 90; gh run list --workflow stale-check.yml --limit 1
```
Expected: `failure`, E-Mail von GitHub „Run failed: stale-check" trifft ein. Danach `gh workflow run stale-check.yml` → `success`.

- [ ] **Phase 4 (Claude, erst nach 3d–3f grün): Rückbau**

```bash
git rm bin/start-daily-loop.sh bin/loop.sh bin/verify-daily-loop.sh bin/fix-selinux-launcher.sh
sudo semanage fcontext -d "$PWD/bin/start-daily-loop.sh" 2>/dev/null || true   # (Marc) alte Datei-Regel
grep -rn "start-daily-loop\|loop.sh\|daily-loop\|healthcheck" CLAUDE.md bin scripts install.sh README.md 2>/dev/null
```
Expected: keine Treffer außer im Historie-Absatz von CLAUDE.md. Dann Memory-Eintrag wie in Task 13 Step 6 anpassen, in einer frischen interaktiven Session `/cron list` prüfen (muss leer sein), und:

```bash
bash tests/run-all.sh && ./bin/check.sh
git add -A bin CLAUDE.md
git commit -m "rückbau: Background-Session-Skripte entfernt, Tageslauf ist systemd-Oneshot

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
git push origin main
```

---

## Self-Review (gegen Spec v2.1)

**Spec-Abdeckung**

| Spec | Task |
|---|---|
| 5.1 Units (daily, alert@, watchdog, youtube), SELinux-Regel, bash-Exec, TimeoutStopSec, Startlimit 12 h/3, RestartPreventExitStatus | 10 |
| 5.2 run-daily.sh: Lock, Zähler/GIVEUP, Dirt, Repo (Stash vor fetch), push-only, Sicherung, Lauf, Klassifikation, verify, Cleanup-Guard, last-run.json, healthchecks | 4, 5 |
| 5.3 verify-briefing.sh `--pre-deploy`/`--full`, Schwellen kalibriert, Manifest-Abgleich | 3 |
| 5.4 alert.sh: Journal, Statusdateien, pro-Kanal-Stempel, pending mit Obergrenze, unit-failed, `last-failure.<unit>` | 2 |
| 5.5 watchdog.sh: alle neun Prüfungen inkl. Live-Check mit Timeout/Temp-Dir, STALE-Unterdrückung | 6 |
| 5.6 Env-Dateien, set-token.sh, Formatprüfung | 1, 7, 10 |
| 5.7 DAILY_UPDATE.md | 8 |
| 5.8 deploy.sh | 9 |
| 5.9 check.sh | 12 |
| 5.10 install.sh Reihenfolge, Env-Prüfung, alte Units | 10 |
| 5.11 GitHub-Workflow | 11 |
| 6 Sicherheit (InaccessiblePaths, strict-mcp, Pathspec, kein Token in Logs) | 5, 9, 10 |
| 7 Migration/Rückbau | 14 |
| 8 Tests | 1–7 (`tests/`), 10 (`verify-daily.sh`) |

**Bewusst nicht im Plan** (Spec Phase 5, optional): WhatsApp-Channel-Plugin, Fine-grained-PAT per `LoadCredential`, `~/.claude/.credentials.json` unzugänglich machen. Eigener Plan, wenn gewünscht.

**Platzhalter-Scan**: keine „TBD/TODO/später"; jeder Code-Schritt enthält den Code. Schwellen (`MIN_WORDS=750`, `MIN_CARDS=2`) sind aus dem Briefing vom 24.09. (1524 Wörter, 6 Karten) abgeleitet; Task 3 Step 5 prüft sie gegen den Ist-Stand am Tag der Umsetzung.

**Typ-/Namenskonsistenz**: `classify_result` gibt `<code> <ART> <text>` (Task 4) — `run-daily.sh` liest `code`/`kind`/`text` per `cut` (Task 5). `last-failure.<kurz>` = Zeile 1 ART, Zeile 2 Text (Task 5 schreibt, Task 2 liest). `verify-briefing.sh` endet mit `RESULT: …`, Exit 0/6/10 (Task 3) — Task 5 mappt 6→OUTCOME, sonst→QUALITY. Watchdog nutzt `alert.sh <ART> <Text> [--force]` (Task 6 ↔ Task 2: `--force` wird positionsunabhängig geparst). `WD_NOW_*`, `LOCK_WAIT_SEC`, `ALERT_CURL`, `DAILY_ENV`/`ALERT_ENV` sind die einzigen Test-Haken und in den Interfaces genannt.
