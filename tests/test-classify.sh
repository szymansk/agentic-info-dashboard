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
assert_eq "own" "$(printf ' M "dashboards/ai-news/x y.html"\n' | classify_dirt)" "quoted own path → own"
assert_eq "foreign" "$(printf ' M "dashboards/ai-news/x y.html"\n M DAILY_UPDATE.md\n' | classify_dirt)" "quoted + foreign"
test_summary
