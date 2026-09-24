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
printf 'A=$(x)\n' > "$T_ROOT/bad4.env"
assert_rc 1 "\$-Expansion im Wert ungültig" -- env_file_valid "$T_ROOT/bad4.env"
printf 'A=`x`\n' > "$T_ROOT/bad5.env"
assert_rc 1 "Backtick-Expansion im Wert ungültig" -- env_file_valid "$T_ROOT/bad5.env"

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
assert_eq "$STUB_BIN/claude" "$(CLAUDE_BIN="$STUB_BIN/claude" resolve_claude)" "resolve_claude via CLAUDE_BIN-Override"
test_summary
