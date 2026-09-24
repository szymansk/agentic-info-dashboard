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
  rm -rf "$T_ROOT/origin.git"  # mk_repo läuft mehrfach pro Testdatei; ohne rm bliebe altes bare-Repo mit fremder Historie stehen → non-fast-forward
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
# run() wird stets als "$(run …)" aufgerufen → läuft in einer Subshell; eine
# einfache Variablenzuweisung an "out" käme dort nie im Elternprozess an.
# Deshalb Ausgabe zusätzlich in eine Datei spiegeln (Dateien sind zwischen
# Subshell und Elternprozess sichtbar, Variablen nicht).
run() { local rc=0; out="$("$V" "$@" 2>&1)" || rc=$?; printf '%s' "$out" > "$T_ROOT/last-out"; echo "$rc"; }
last_out() { cat "$T_ROOT/last-out" 2>/dev/null; }

mk_repo; good_today
assert_eq "0" "$(run --pre-deploy --date "$D1")" "pre-deploy ok"
assert_eq "6" "$(run --full --date "$D1")" "full vor Deploy → not-deployed"
deploy_today
assert_eq "0" "$(run --full --date "$D1")" "full nach Deploy ok"
assert_contains "RESULT: ok" "$(last_out)" "RESULT-Zeile"

# Datum-only-Update: Text identisch mit gestern → quality
mk_repo; good_today; page "$D1" live 80 3 alt > "$R/dashboards/ai-news/index.html"
assert_eq "10" "$(run --pre-deploy --date "$D1")" "identischer Text → quality"
assert_contains "identisch" "$(last_out)" "Grund identisch"

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

# Zwischen-Commits ohne index.html-Touch dürfen die PREV-Suche nicht
# verkürzen (Fix Runde 1): index.html erst committen, dann mehrere
# themenfremde Commits (notes/*.txt), die den "heute"-Commit weiter als
# HEAD~3 zurückschieben. Nur so unterscheidet der Test alte (HEAD..HEAD~3)
# von neuer (Datei-Historie über "git log -- <pfad>") PREV-Suche — mit
# unverändertem index.html bliebe der Inhalt über beliebig viele
# Zwischen-Commits identisch und selbst die alte Suche fände ihn sofort.
mk_repo; good_today
git -C "$R" add dashboards/ai-news/index.html; git -C "$R" commit -qm heute-index
mkdir -p "$R/notes"
for f in a b c d; do
  printf '%s\n' "$f" > "$R/notes/$f.txt"
  git -C "$R" add "notes/$f.txt"; git -C "$R" commit -qm "infra $f"
done
assert_eq "0" "$(run --pre-deploy --date "$D1")" "PREV trotz >3 themenfremden Zwischen-Commits gefunden (happy path)"
rm "$R/dashboards/ai-news/archive/$D0.html"
assert_eq "10" "$(run --pre-deploy --date "$D1")" "Archiv-Check feuert trotz >3 themenfremden Zwischen-Commits"

assert_rc 64 "usage" -- "$V"
test_summary
