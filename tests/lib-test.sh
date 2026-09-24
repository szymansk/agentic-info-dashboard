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
