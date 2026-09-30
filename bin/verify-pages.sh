#!/usr/bin/env bash
#
# verify-pages.sh — Ergebnisprüfung des Wochenlaufs (JOB=weekly) für statische
# Seiten mit data-snapshot-date (Regulatorik, Coding-Tools, Kalender, Extensions).
#
#   verify-pages.sh --pre-deploy|--full [--date D] <seite.html>…
#     --pre-deploy  Quellseiten: Datum ≥ D, vollständiges HTML, nicht geschrumpft
#     --full        zusätzlich docs/-Kopie mit gleichem Datum, Tree clean, nichts ahead
#                   (Aufrufer hat vorher `git fetch` gemacht)
#   Schwellen: MIN_SIZE_RATIO (0.5) — neue Seite muss ≥ 50 % der committeten Vorversion haben;
#              Kalender: CAL_MIN_MONTHS (10) Monatsblöcke, CAL_MIN_EVENTS (20) Termine
# Exit: 0 ok · 6 not-deployed · 10 quality · 64 Usage
#
set -uo pipefail
LOG_TAG=verify-pages
# shellcheck source=bin/lib-daily.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-daily.sh"

usage() { echo "usage: verify-pages.sh --pre-deploy|--full [--date D] <seite.html>…" >&2; exit 64; }
MODE=""; DATE="$(today)"; PAGES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --pre-deploy|--full) MODE="${1#--}" ;;
    --date) DATE="${2:-}"; shift ;;
    -*) usage ;;
    *) PAGES+=("$1") ;;
  esac
  shift
done
[ -n "$MODE" ] && [ "${#PAGES[@]}" -gt 0 ] || usage
cd "$PROJECT_DIR" || exit 64

CLEAN=1; AHEAD=0
if [ "$MODE" = full ]; then
  [ -z "$(git status --porcelain --untracked-files=all)" ] || CLEAN=0
  AHEAD="$(git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)"
fi
# committete Vorversion je Seite (Größenvergleich gegen Abschneiden/Leerseiten)
PREV_DIR="$(mktemp -d)"; trap 'rm -rf "$PREV_DIR"' EXIT
for p in "${PAGES[@]}"; do
  rev="$(git log -n 20 --format=%H -- "$p" 2>/dev/null | while read -r h; do
           d="$(git show "$h:$p" 2>/dev/null | grep -oE 'data-snapshot-date="[0-9-]{10}"' | head -1 | grep -oE '[0-9-]{10}')"
           if [ -n "$d" ] && [[ "$d" < "$DATE" ]]; then echo "$h"; break; fi
         done)"
  [ -n "$rev" ] && git show "$rev:$p" > "$PREV_DIR/$(echo "$p" | tr / _)" 2>/dev/null
done

python3 - "$MODE" "$DATE" "$PREV_DIR" "$CLEAN" "$AHEAD" "${PAGES[@]}" <<'PY'
import os, re, sys
from html.parser import HTMLParser
mode, run_date, prev_dir, clean, ahead, *pages = sys.argv[1:]
ratio = float(os.environ.get("MIN_SIZE_RATIO", "0.5"))
fails = []
def ok(m): print("ok  " + m)
def fail(cls, m): fails.append((cls, m)); print(f"FAIL[{cls}] {m}")
def read(p):
    try: return open(p, encoding="utf-8", errors="replace").read()
    except FileNotFoundError: return None
def sdate(s):
    m = re.search(r'data-snapshot-date="(\d{4}-\d{2}-\d{2})"', s or ""); return m.group(1) if m else ""
class Check(HTMLParser):
    def __init__(s): super().__init__(); s.tags = set()
    def handle_starttag(s, t, a): s.tags.add(t)
    def handle_endtag(s, t): s.tags.add("/" + t)

for p in pages:
    name = p.split("/")[-2] if "/" in p else p
    src = read(p)
    if src is None: fail("quality", f"{name}: Seite fehlt ({p})"); continue
    d = sdate(src)
    if d and d >= run_date: ok(f"{name}: Stand {d}")
    else: fail("not-deployed", f"{name}: Stand {d or 'fehlt'} < {run_date}")
    c = Check()
    try: c.feed(src)
    except Exception as e: fail("quality", f"{name}: HTML nicht parsebar: {e}"); continue
    if {"/body", "/html"} <= c.tags: ok(f"{name}: HTML vollständig")
    else: fail("quality", f"{name}: HTML unvollständig (kein </body>/</html>)")
    if name == "calendar":  # 12-Monats-Fenster muss tatsächlich gefüllt sein
        months = len(re.findall(r"<h2>", src)); events = len(re.findall(r'<article class="event"', src))
        mm = int(os.environ.get("CAL_MIN_MONTHS", "10")); me = int(os.environ.get("CAL_MIN_EVENTS", "20"))
        if months < mm or events < me:
            fail("quality", f"calendar: nur {months} Monatsblöcke / {events} Termine (Minimum {mm} / {me})")
        else: ok(f"calendar: {months} Monatsblöcke / {events} Termine")
    prev = read(os.path.join(prev_dir, p.replace("/", "_")))
    if prev and len(src) < ratio * len(prev):
        fail("quality", f"{name}: auf {len(src)} Bytes geschrumpft (Vorversion {len(prev)})")
    if mode == "full":
        docs = "docs/" + p.split("dashboards/", 1)[-1]
        dd = sdate(read(docs))
        if dd == d: ok(f"{name}: docs/ Stand {dd}")
        else: fail("not-deployed", f"{name}: docs/ Stand {dd or 'fehlt'} ≠ {d or '?'}")

if mode == "full":
    if clean == "1": ok("Working Tree clean")
    else: fail("not-deployed", "Working Tree nicht clean")
    if ahead == "0": ok("nichts ahead von origin/main")
    else: fail("not-deployed", f"{ahead} Commit(s) nicht gepusht")

if not fails: print("RESULT: ok"); sys.exit(0)
q = [f for f in fails if f[0] == "quality"]
if q: print("RESULT: quality: " + q[0][1]); sys.exit(10)
print("RESULT: not-deployed: " + fails[0][1]); sys.exit(6)
PY
