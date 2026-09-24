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
