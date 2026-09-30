#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
. tests/lib-test.sh; test_sandbox
V="$PWD/bin/verify-pages.sh"
D1="$(date -I)"; D0="$(date -I -d "$D1 - 8 day")"
PAGES=(dashboards/regulation/index.html dashboards/coding-tools/index.html)

page() { printf '<html><head><title>t</title></head><body data-snapshot-date="%s" data-snapshot-mode="live"><h1>x</h1><p>%s</p></body></html>\n' "$1" "${2:-inhalt}"; }
mk_repo() {
  R="$T_ROOT/repo"; rm -rf "$R" "$T_ROOT/origin.git"
  mkdir -p "$R/dashboards/regulation" "$R/dashboards/coding-tools" "$R/docs/regulation" "$R/docs/coding-tools"
  git -C "$R" init -q -b main; git -C "$R" config user.email t@t; git -C "$R" config user.name t
  for p in "${PAGES[@]}"; do page "$D0" > "$R/$p"; cp "$R/$p" "$R/docs/${p#dashboards/}"; done
  git -C "$R" add -A; git -C "$R" commit -qm alt
  git init -q --bare "$T_ROOT/origin.git"; git -C "$R" remote add origin "$T_ROOT/origin.git"; git -C "$R" push -q -u origin main
  export PROJECT_DIR="$R"
}
update_today() { for p in "${PAGES[@]}"; do page "$D1" neu > "$R/$p"; done; }
build_push() {  # wie build-pages.py: docs/ spiegelt dashboards/
  for p in "${PAGES[@]}"; do cp "$R/$p" "$R/docs/${p#dashboards/}"; done
  git -C "$R" add -A; git -C "$R" commit -qm heute; git -C "$R" push -q origin main
}
run() { local rc=0; "$V" "$@" > "$T_ROOT/out" 2>&1 || rc=$?; echo "$rc"; }

mk_repo
assert_eq "6" "$(run --pre-deploy --date "$D1" "${PAGES[@]}")" "alte Seiten → not-deployed"
update_today
assert_eq "0" "$(run --pre-deploy --date "$D1" "${PAGES[@]}")" "pre-deploy nach Update ok"
assert_eq "6" "$(run --full --date "$D1" "${PAGES[@]}")" "full vor Deploy → not-deployed"
build_push
assert_eq "0" "$(run --full --date "$D1" "${PAGES[@]}")" "full nach Deploy ok"
assert_contains "RESULT: ok" "$(cat "$T_ROOT/out")" "RESULT-Zeile"

# nur eine Seite aktualisiert → not-deployed, Grund nennt die alte Seite
mk_repo; page "$D1" neu > "$R/${PAGES[0]}"
assert_eq "6" "$(run --pre-deploy --date "$D1" "${PAGES[@]}")" "eine Seite alt → 6"
assert_contains "coding-tools" "$(cat "$T_ROOT/out")" "Grund nennt die alte Seite"

# kaputtes HTML (Body abgeschnitten, fast leer) → quality
mk_repo; update_today; printf '<html><body data-snapshot-date="%s">' "$D1" > "$R/${PAGES[1]}"
assert_eq "10" "$(run --pre-deploy --date "$D1" "${PAGES[@]}")" "abgeschnittene Seite → quality"

# Seite deutlich geschrumpft (< 50 % der Vorversion) → quality
mk_repo  # Vorversion (Stand D0) ist groß, die heutige nur ein Rumpf
printf '%*s' 4000 '' | tr ' ' 'a' > "$T_ROOT/pad"; page "$D0" "$(cat "$T_ROOT/pad")" > "$R/${PAGES[1]}"
git -C "$R" commit -qam gross; git -C "$R" push -q origin main
update_today; page "$D1" kurz > "$R/${PAGES[1]}"
assert_eq "10" "$(run --pre-deploy --date "$D1" "${PAGES[@]}")" "stark geschrumpft → quality"

# docs/ nicht aktualisiert, aber gepusht → not-deployed
mk_repo; update_today; git -C "$R" commit -qam nur-quelle; git -C "$R" push -q origin main
assert_eq "6" "$(run --full --date "$D1" "${PAGES[@]}")" "docs alt → not-deployed"

assert_rc 64 "usage" -- "$V"
assert_rc 64 "keine Seiten" -- "$V" --full
test_summary
