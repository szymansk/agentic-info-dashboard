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
  # dashboards/it-services bleibt absichtlich UNgeschaffen: es steht zwar in
  # OWN_DIRT_PATHS (lib-daily.sh), aber run-daily.sh muss auch dann stashen
  # können, wenn ein own-dirt-Pfad im Working Tree gar nicht existiert — das
  # ist die Regression, die existing_own_paths() (Fix-Runde 1, Item 7) abfängt.
  R="$T_ROOT/repo"; rm -rf "$R" "$T_ROOT/origin.git"; mkdir -p "$R/dashboards/ai-news/archive" "$R/docs/ai-news/archive" "$R/bin"
  git -C "$R" init -q -b main; git -C "$R" config user.email t@t; git -C "$R" config user.name t
  printf 'dashboards/ai-news/archive/*.html\ndashboards/ai-news/archive/manifest.json\nbin/\n' > "$R/.gitignore"
  page "$D0" live 80 3 alt > "$R/dashboards/ai-news/index.html"; cp "$R/dashboards/ai-news/index.html" "$R/docs/ai-news/index.html"
  manifest "$(entry "$D0" /ai-news/)" > "$R/dashboards/ai-news/archive/manifest.json"; cp "$R/dashboards/ai-news/archive/manifest.json" "$R/docs/ai-news/archive/manifest.json"
  echo prompt > "$R/DAILY_UPDATE.md"
  git -C "$R" add -A; git -C "$R" commit -qm gestern
  git init -q --bare "$T_ROOT/origin.git"; git -C "$R" remote add origin "$T_ROOT/origin.git"; git -C "$R" push -q -u origin main
  # Skripte aus dem echten bin/ verlinken, damit run-daily.sh seine Nachbarn findet
  ln -sf "$BIN/lib-daily.sh" "$BIN/verify-briefing.sh" "$BIN/run-daily.sh" "$R/bin/"
  export PROJECT_DIR="$R"; rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"; : > "$STUB_BIN/claude.log"; : > "$STUB_BIN/curl.log"
}
# claude-Stub: CLAUDE_STUB=<fixture|/abs-pfad|ok-full|ok-nothing|half-then-529>
stub claude 'echo "$@" >> "$STUB_BIN/claude.log"
# fd9 (run.lock) darf beim echten Workflow-Aufruf (-p) nicht vererbt sein
# (Fix-Runde 1, Item 1) — sonst hält dieser Kindprozess das Lock fest über
# das Ende von run-daily.sh hinaus.
[ "${1:-}" = "-p" ] && [ -e "/proc/$$/fd/9" ] && echo FD9_OPEN >> "$STUB_BIN/claude.log"
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
  /*) cat "$CLAUDE_STUB"; exit 1 ;;
  *) cat "$FIX/$CLAUDE_STUB"; exit 1 ;;
esac'
export FIX T_ROOT
stub curl 'printf "<body data-snapshot-date=\"%s\">" "$(date -I)"; echo "$@" >> "$STUB_BIN/curl.log"'
# run() wird stets als "$(run …)" aufgerufen → läuft in einer Subshell; eine
# einfache Variablenzuweisung an "out" käme dort nie im Elternprozess an.
# Deshalb Ausgabe zusätzlich in eine Datei spiegeln (Dateien sind zwischen
# Subshell und Elternprozess sichtbar, Variablen nicht) — gleiches Muster wie
# tests/test-verify-briefing.sh.
# CLAUDE_BIN erzwingt den Stub direkt (lib-daily.sh Fix-Runde 1, Item 4):
# resolve_claude() prüft CLAUDE_BIN vor $HOME/.local/bin/claude — auf dieser
# Maschine liegt dort ein echtes claude-Binary, das sonst statt des Stubs
# aufgerufen würde (und mit dem Fake-Token real mit 401 scheitert).
export CLAUDE_BIN="$STUB_BIN/claude"
run() { local rc=0; out="$(cd "$R" && "$R/bin/run-daily.sh" "$@" 2>&1 </dev/null)" || rc=$?; printf '%s' "$out" > "$T_ROOT/last-out"; echo "$rc"; }
last_out() { cat "$T_ROOT/last-out" 2>/dev/null; }

# 1. Token fehlt → 3, kein State
mk_repo; : > "$DAILY_ENV"
assert_eq "3" "$(run)" "Token fehlt → 3"; assert_eq "AUTH" "$(sed -n 1p "$STATE_DIR/last-failure.daily")" "last-failure AUTH"
printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-test\nCLAUDE_MODEL=test-model\nMAX_BUDGET_USD=1\n' > "$DAILY_ENV"

# 2. fremder Dirt → 4
mk_repo; echo x > "$R/notiz.txt"
assert_eq "4" "$(run)" "fremder Dirt → 4"; assert_contains "notiz.txt" "$(last_out)" "Pfad im Text"

# 3. idempotent: heute schon gepusht → 0, claude nicht aufgerufen, Alt-State geräumt
mk_repo; CLAUDE_STUB=ok-full "$STUB_BIN/claude" >/dev/null 2>&1; : > "$STUB_BIN/claude.log"
# Reste eines früheren Fehlschlags simulieren — die Idempotenz-Kurzschluss-
# Zeile muss sie räumen (Fix-Runde 1, Item 6), sonst bleibt der Vorfall im
# State stehen, obwohl das Ergebnis (Briefing gepusht) längst in Ordnung ist.
echo 1 > "$STATE_DIR/attempts.$D1"
printf 'AUTH\nalter Fehlschlag\n' > "$STATE_DIR/last-failure.daily"
printf 'AUTH\n2020-01-01T00:00:00+0000\nalt\n' > "$STATE_DIR/last-alert"
assert_eq "0" "$(run)" "schon erledigt → 0"; assert_eq "" "$(cat "$STUB_BIN/claude.log")" "claude nicht aufgerufen"
assert_eq "" "$(cat "$STATE_DIR/attempts.$D1" 2>/dev/null)" "Zähler bei Idempotenz geräumt"
assert_eq "" "$(cat "$STATE_DIR/last-failure.daily" 2>/dev/null)" "last-failure bei Idempotenz geräumt"
assert_eq "" "$(cat "$STATE_DIR/last-alert" 2>/dev/null)" "last-alert bei Idempotenz geräumt"

# 4. push-only: committet, nicht gepusht → pusht, 0, claude nicht aufgerufen
mk_repo; ( cd "$R" && . "$T_ROOT/gen.sh" && page "$D1" live 80 3 neu > dashboards/ai-news/index.html && page "$D0" archive 80 3 alt > "dashboards/ai-news/archive/$D0.html" \
  && manifest "$(entry "$D0" "/ai-news/archive/$D0.html"),$(entry "$D1" /ai-news/)" > dashboards/ai-news/archive/manifest.json \
  && cp dashboards/ai-news/index.html docs/ai-news/index.html && cp dashboards/ai-news/archive/manifest.json docs/ai-news/archive/manifest.json \
  && git add -A && git commit -qm heute ); : > "$STUB_BIN/claude.log"
# Stehengebliebener prev-snapshot-Rest eines früheren Laufs (alte mtime,
# falsches Datum ohne passendes Archiv) — push-only durchläuft Schritt 6
# nicht, darf diesen Rest also nicht an verify-briefing.sh weiterreichen
# (Fix-Runde 1, Item 5), sonst schlägt die Prüfung mit "archive/1999-01-01
# .html fehlt" fehl statt mit 0 durchzulaufen.
printf '1999-01-01\n' > "$STATE_DIR/prev-snapshot"; touch -d '-1 hour' "$STATE_DIR/prev-snapshot"
assert_eq "0" "$(run)" "push-only → 0"
# write_last_run() fragt "$CLAUDE_BIN" --version für die last-run.json-CLI-
# Version ab (harmlos, kein API-Call) — nur ein echter claude -p-Lauf
# (Workflow-Invocation) zählt hier als "claude aufgerufen".
assert_eq "" "$(grep -v '^--version$' "$STUB_BIN/claude.log" 2>/dev/null)" "push-only ohne echten claude -p-Lauf"
assert_eq "0" "$(git -C "$R" rev-list --count origin/main..HEAD)" "gepusht"

# 5. 401 → 3
mk_repo; export CLAUDE_STUB=result-401.json
assert_eq "3" "$(run)" "401 → 3"; assert_contains "AUTH" "$(cat "$STATE_DIR/last-failure.daily")" "AUTH im last-failure"
assert_eq "" "$(cat "$STATE_DIR/attempts.$D1" 2>/dev/null)" "AUTH zählt nicht als Versuch"

# 6. 3× 529 → 5, 5, 11 (GIVEUP)
mk_repo; export CLAUDE_STUB="$T_ROOT/result-529.json"
printf '{"is_error":true,"api_error_status":529,"terminal_reason":"api_error","result":"overloaded"}' > "$T_ROOT/result-529.json"
assert_eq "5" "$(run)" "529 #1 → 5"; assert_eq "1" "$(cat "$STATE_DIR/attempts.$D1")" "attempts=1"
assert_eq "" "$(grep -o '/fail' "$STUB_BIN/curl.log")" "kein /fail bei retrybarem 5"
assert_eq "5" "$(run)" "529 #2 → 5"; assert_eq "2" "$(cat "$STATE_DIR/attempts.$D1")" "attempts=2"
assert_eq "11" "$(run)" "529 #3 → 11 GIVEUP"; assert_eq "GIVEUP" "$(sed -n 1p "$STATE_DIR/last-failure.daily")" "GIVEUP im last-failure"
assert_contains "/fail" "$(cat "$STUB_BIN/curl.log")" "healthchecks /fail bei GIVEUP"

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
assert_contains "--strict-mcp-config" "$(cat "$STUB_BIN/claude.log")" "strict-mcp-config gesetzt"
assert_contains "AskUserQuestion" "$(cat "$STUB_BIN/claude.log")" "AskUserQuestion gesperrt"
assert_eq "" "$(grep -o FD9_OPEN "$STUB_BIN/claude.log")" "claude -p sieht fd9 (run.lock) nicht"
assert_rc 0 "Lock nach Erfolg wieder frei" -- flock -n "$STATE_DIR/run.lock" true

# 10. dry-run: Token fehlt → 3; sonst 0 ohne claude
mk_repo; : > "$DAILY_ENV"; assert_eq "3" "$(run --dry-run)" "dry-run ohne Token → 3"
printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-test\n' > "$DAILY_ENV"; : > "$STUB_BIN/claude.log"
assert_eq "0" "$(run --dry-run)" "dry-run → 0"; assert_contains "würde claude -p starten" "$(last_out)" "dry-run Text"
assert_eq "" "$(cat "$STUB_BIN/claude.log")" "dry-run ohne claude"
# dry-run auf bereits gepushtem Briefing (Idempotenz-Kurzschluss, wie Fall 3)
# darf last-alert NICHT löschen (Fix-Runde 2, Item 1) — check.sh ruft
# --dry-run bei jedem Aufruf; das wäre sonst ein Nebeneffekt auf den
# Alarm-State bei einem reinen Preflight-Check.
mk_repo; CLAUDE_STUB=ok-full "$STUB_BIN/claude" >/dev/null 2>&1
printf 'AUTH\n2020-01-01T00:00:00+0000\nalt\n' > "$STATE_DIR/last-alert"
assert_eq "0" "$(run --dry-run)" "dry-run auf gepushtem Briefing → 0"
assert_eq "AUTH" "$(sed -n 1p "$STATE_DIR/last-alert" 2>/dev/null)" "last-alert bei dry-run nicht geräumt"

# 11. Lock belegt → 0 ohne Alarm
mk_repo; ( exec 9>"$STATE_DIR/run.lock"; flock 9; sleep 3 ) & sleep 0.3
assert_eq "0" "$(run)" "Lock belegt → 0"; assert_contains "Lock" "$(last_out)" "Lock-Hinweis"; wait
test_summary
