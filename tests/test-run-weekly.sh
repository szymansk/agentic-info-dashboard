#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
. tests/lib-test.sh; test_sandbox
BIN="$PWD/bin"; FIX="$PWD/tests/fixtures"
export JOB=weekly LOCK_WAIT_SEC=1 CAL_MIN_MONTHS=0 CAL_MIN_EVENTS=0  # Kalenderinhalt prüft test-verify-pages.sh
export DAILY_ENV="$CONF_DIR/daily.env" ALERT_ENV="$CONF_DIR/alert.env"
printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-test\nCLAUDE_MODEL=test-model\nMAX_BUDGET_USD=1\n' > "$DAILY_ENV"
: > "$ALERT_ENV"
D1="$(date -I)"; D0="$(date -I -d "$D1 - 7 day")"
PAGES="regulation coding-tools calendar extensions"
stub logger 'exit 0'
stub curl 'printf "<body data-snapshot-date=\"%s\">" "$(date -I)"'

cat > "$T_ROOT/gen.sh" <<'GEN'
page() { printf '<html><head><title>t</title></head><body data-snapshot-date="%s" data-snapshot-mode="live"><h1>%s</h1><p>Inhalt der Seite %s</p></body></html>\n' "$1" "$2" "$2"; }
GEN
. "$T_ROOT/gen.sh"

mk_repo() {
  R="$T_ROOT/repo"; rm -rf "$R" "$T_ROOT/origin.git"; mkdir -p "$R/bin"
  git -C "$R" init -q -b main; git -C "$R" config user.email t@t; git -C "$R" config user.name t
  printf 'bin/\n' > "$R/.gitignore"
  for d in $PAGES; do mkdir -p "$R/dashboards/$d" "$R/docs/$d"; page "$D0" "$d" > "$R/dashboards/$d/index.html"; cp "$R/dashboards/$d/index.html" "$R/docs/$d/index.html"; done
  echo prompt > "$R/WEEKLY_UPDATE.md"
  git -C "$R" add -A; git -C "$R" commit -qm alt
  git init -q --bare "$T_ROOT/origin.git"; git -C "$R" remote add origin "$T_ROOT/origin.git"; git -C "$R" push -q -u origin main
  ln -sf "$BIN/lib-daily.sh" "$BIN/verify-pages.sh" "$BIN/run-daily.sh" "$R/bin/"
  export PROJECT_DIR="$R"; rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"; : > "$STUB_BIN/claude.log"
}
stub claude 'echo "$@" >> "$STUB_BIN/claude.log"
[ "${1:-}" = "--version" ] && { echo "stub 0.0"; exit 0; }
. "$T_ROOT/gen.sh"; cd "$PROJECT_DIR"
case "$CLAUDE_STUB" in
  ok-full) for d in regulation coding-tools calendar extensions; do page "$(date -I)" "$d" > "dashboards/$d/index.html"; cp "dashboards/$d/index.html" "docs/$d/index.html"; done
           git add dashboards docs; git commit -qm "weekly: seiten $(date -I)"; git push -q origin main; cat "$FIX/result-ok.json" ;;
  ok-nothing) cat "$FIX/result-ok.json" ;;
esac'
export FIX T_ROOT CLAUDE_BIN="$STUB_BIN/claude"
run() { local rc=0; (cd "$R" && "$R/bin/run-daily.sh" "$@") > "$T_ROOT/last-out" 2>&1 </dev/null || rc=$?; echo "$rc"; }

# 1. Erfolg: Seiten aktualisiert + gepusht → 0, eigener State, Tageslauf-State unberührt
mk_repo; export CLAUDE_STUB=ok-full
printf 'GIVEUP\nx\n' > "$STATE_DIR/last-alert"
assert_eq "0" "$(run)" "Wochenlauf Erfolg → 0"
assert_eq "0" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["exit"])' "$STATE_DIR/last-run-weekly.json")" "last-run-weekly.json exit 0"
assert_eq "" "$(ls "$STATE_DIR"/last-run.json 2>/dev/null)" "last-run.json (Tageslauf) nicht angelegt"
assert_eq "GIVEUP" "$(sed -n 1p "$STATE_DIR/last-alert")" "Tageslauf-Alarm bleibt stehen"
assert_contains "WEEKLY_UPDATE.md" "$(cat "$STUB_BIN/claude.log")" "Prompt verweist auf WEEKLY_UPDATE.md"
assert_contains "Weekly-Update-Workflow" "$(cat "$STUB_BIN/claude.log")" "Auftragstext Weekly"

# 2. Lauf ohne Ergebnis → 6 OUTCOME, last-failure.weekly, eigener Zähler
mk_repo; export CLAUDE_STUB=ok-nothing
assert_eq "6" "$(run)" "kein Ergebnis → 6"
assert_eq "OUTCOME" "$(sed -n 1p "$STATE_DIR/last-failure.weekly")" "last-failure.weekly OUTCOME"
assert_eq "1" "$(cat "$STATE_DIR/attempts-weekly.$D1")" "Zähler attempts-weekly"
assert_eq "" "$(ls "$STATE_DIR"/last-failure.daily "$STATE_DIR"/attempts."$D1" 2>/dev/null)" "kein Tageslauf-State"
assert_contains "regulation" "$(cat "$T_ROOT/last-out")" "Grund nennt die alte Seite"

# 3. alle Seiten schon aktuell und gepusht → 0 ohne claude -p
mk_repo; CLAUDE_STUB=ok-full "$STUB_BIN/claude" >/dev/null 2>&1; : > "$STUB_BIN/claude.log"
assert_eq "0" "$(run)" "schon aktuell → 0"
assert_eq "" "$(grep -v '^--version$' "$STUB_BIN/claude.log")" "kein claude -p"

# 3b. FORCE_RUN=1 startet trotz aktuellem Stand
: > "$STUB_BIN/claude.log"
assert_eq "0" "$(FORCE_RUN=1 run)" "FORCE_RUN → Lauf"
assert_contains "-p --output-format json" "$(cat "$STUB_BIN/claude.log")" "claude -p trotz aktuellem Stand"
assert_contains "erzwungener Nachlauf" "$(cat "$STUB_BIN/claude.log")" "Prompt überspringt Idempotenz"

# 4. nur eine Seite aktuell → Lauf startet (ältestes Datum zählt)
mk_repo; export CLAUDE_STUB=ok-full
page "$D1" regulation > "$R/dashboards/regulation/index.html"; cp "$R/dashboards/regulation/index.html" "$R/docs/regulation/index.html"
git -C "$R" commit -qam teil; git -C "$R" push -q origin main; : > "$STUB_BIN/claude.log"
assert_eq "0" "$(run)" "Teilstand → voller Lauf → 0"
assert_contains "-p --output-format json" "$(cat "$STUB_BIN/claude.log")" "claude -p lief"

# 5. Sperre wird mit dem Tageslauf geteilt (gleiches run.lock)
mk_repo; ( exec 9>"$STATE_DIR/run.lock"; flock 9; sleep 3 ) & sleep 0.3
assert_eq "0" "$(run)" "Lock belegt → 0 ohne Alarm"; assert_contains "Lock" "$(cat "$T_ROOT/last-out")" "Lock-Hinweis"; wait

# 6. unbekannter JOB → 64
assert_eq "64" "$(JOB=monthly run)" "unbekannter JOB → 64"
test_summary
