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
