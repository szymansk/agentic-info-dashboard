#!/usr/bin/env python3
"""
Build the static GitHub-Pages site from the dashboards/ folder.

What it does:
1. Copies dashboards/ → docs/
2. Rewrites absolute paths /foo → /agentic-info-dashboard/foo
   (sowohl HTML-Attribute href/src als auch JS-fetch-Calls)
3. Generates docs/index.html als statische Landing-Page
   (das, was serve.py live rendert)
4. Schreibt docs/.nojekyll, damit Pages keine _shared/-Dateien ignoriert

Pages-Source = main branch, /docs folder.
Lokales serve.py + dashboards/ bleiben unangetastet.
"""

import json
import re
import shutil
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "dashboards"
DST = ROOT / "docs"

# Pages-URL: https://szymansk.github.io/agentic-info-dashboard/
# Alle absoluten Pfade müssen das Repo als Präfix bekommen.
PREFIX = "/agentic-info-dashboard"


def rewrite_paths(text: str) -> str:
    """Rewrites absolute paths beginning with single / to /<PREFIX>/."""
    # HTML attrs: href="/..." and src="/..." (NOT //protocol-relative)
    text = re.sub(
        r'((?:href|src)=)"(/(?!/)[^"]*)"',
        rf'\1"{PREFIX}\2"',
        text,
    )
    # JS fetch('/...') and fetch("/...")
    text = re.sub(
        r'(fetch\()(["\'])(/(?!/)[^"\']*)\2',
        rf'\1\2{PREFIX}\3\2',
        text,
    )
    return text


def discover_dashboards():
    """Mirror of serve.py:discover_dashboards()."""
    items = []
    for entry in sorted(SRC.iterdir(), key=lambda p: p.name.lower()):
        if not entry.is_dir() or not (entry / "index.html").exists():
            continue
        meta = {}
        meta_path = entry / ".meta.json"
        if meta_path.exists():
            try:
                meta = json.loads(meta_path.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                pass
        mtime = (entry / "index.html").stat().st_mtime
        items.append({
            "slug": entry.name,
            "title": meta.get("title") or entry.name.replace("-", " ").title(),
            "description": meta.get("description", ""),
            "tag": meta.get("tag", ""),
            "accent": meta.get("accent", "#7aa2f7"),
            "updated": datetime.fromtimestamp(mtime).strftime("%d.%m.%Y · %H:%M"),
        })
    return items


def render_landing(items: list[dict]) -> str:
    """Statische Variante von serve.py:render_index() — Links mit PREFIX."""
    cards = []
    for d in items:
        cards.append(
            f'''<a class="card" href="{PREFIX}/{d['slug']}/" style="--accent:{d['accent']}">
  <div class="card-head">
    <span class="card-tag">{d['tag'] or '—'}</span>
    <span class="card-updated">{d['updated']}</span>
  </div>
  <h2>{d['title']}</h2>
  <p>{d['description']}</p>
  <span class="card-arrow">öffnen <span class="chev">→</span></span>
</a>'''
        )
    body = f'<div class="grid">{"".join(cards)}</div>'
    built = datetime.now().strftime("%d.%m.%Y · %H:%M")

    return f"""<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>AI/Agentic-AI Dashboards</title>
<style>
  :root {{
    --bg: #0b0d12; --panel: #161a24; --panel-2: #1b2030;
    --line: #232a3a; --text: #e7ecf3; --muted: #8b94a8;
    --dim: #5d6577; --accent: #7aa2f7;
  }}
  * {{ box-sizing: border-box; }}
  body {{
    margin: 0;
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, Roboto, 'Helvetica Neue', sans-serif;
    color: var(--text);
    background:
      radial-gradient(1100px 700px at 90% -10%, rgba(195,154,74,.08), transparent 60%),
      radial-gradient(900px 600px at -10% 10%, rgba(122,162,247,.07), transparent 60%),
      var(--bg);
    min-height: 100vh; line-height: 1.55;
  }}
  code {{ font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; color: var(--muted); }}
  a {{ color: inherit; text-decoration: none; }}
  .wrap {{ max-width: 1180px; margin: 0 auto; padding: 40px 28px 80px; }}
  header {{
    display: flex; align-items: baseline; justify-content: space-between;
    gap: 24px; margin-bottom: 32px; padding-bottom: 22px;
    border-bottom: 1px solid var(--line);
  }}
  header h1 {{ margin: 0; font-size: 28px; font-weight: 800; letter-spacing: -.02em; }}
  header .sub {{ color: var(--muted); font-size: 14px; margin-top: 4px; }}
  header .meta {{
    color: var(--muted); font-size: 12px;
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  }}
  header .meta b {{ color: var(--text); }}
  .grid {{
    display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr));
    gap: 14px;
  }}
  .card {{
    position: relative;
    display: flex; flex-direction: column; gap: 8px;
    padding: 18px 18px 16px;
    background: linear-gradient(180deg, var(--panel) 0%, var(--panel-2) 100%);
    border: 1px solid var(--line); border-radius: 14px;
    transition: transform .12s ease, border-color .12s ease, background .12s ease;
    overflow: hidden;
  }}
  .card::before {{
    content: ""; position: absolute; left: 0; top: 0; bottom: 0; width: 3px;
    background: var(--accent); opacity: .8;
  }}
  .card:hover {{ border-color: rgba(122,162,247,.45); transform: translateY(-1px); }}
  .card-head {{
    display: flex; justify-content: space-between; align-items: center;
    font-size: 11px; color: var(--dim);
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    letter-spacing: .04em; text-transform: uppercase;
  }}
  .card-tag {{
    color: var(--accent); border: 1px solid currentColor; padding: 1px 8px;
    border-radius: 999px; font-weight: 600; font-size: 10.5px;
    background: color-mix(in srgb, var(--accent) 8%, transparent);
  }}
  .card h2 {{ margin: 4px 0 0; font-size: 17px; font-weight: 700; letter-spacing: -.005em; }}
  .card p {{ margin: 0; color: var(--muted); font-size: 13.5px; }}
  .card-arrow {{
    margin-top: auto; padding-top: 10px;
    font-size: 12px; color: var(--dim);
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  }}
  .card-arrow .chev {{ transition: transform .15s ease; display: inline-block; }}
  .card:hover .card-arrow {{ color: var(--accent); }}
  .card:hover .card-arrow .chev {{ transform: translateX(3px); }}
  footer {{
    margin-top: 50px; padding-top: 16px;
    border-top: 1px solid var(--line);
    color: var(--dim); font-size: 12px;
    display: flex; justify-content: space-between; flex-wrap: wrap; gap: 8px;
  }}
</style>
</head>
<body>
<div class="wrap">
  <header>
    <div>
      <h1>📊 AI / Agentic-AI Dashboards</h1>
      <div class="sub">{len(items)} Dashboards · gehostet auf GitHub Pages</div>
    </div>
    <div class="meta">build: <b>{built}</b></div>
  </header>
  {body}
  <footer>
    <div>Source: <a href="https://github.com/szymansk/agentic-info-dashboard"><code>szymansk/agentic-info-dashboard</code></a></div>
    <div>Tägliches Update via Claude Code Background-Session</div>
  </footer>
</div>
</body>
</html>"""


def main():
    if not SRC.exists():
        print(f"ERROR: {SRC} not found", file=sys.stderr)
        sys.exit(1)

    # 1. Clean docs/
    if DST.exists():
        shutil.rmtree(DST)

    # 2. Copy dashboards/ → docs/
    shutil.copytree(SRC, DST)

    # 3. Rewrite absolute paths in all .html files
    count = 0
    for html in DST.rglob("*.html"):
        text = html.read_text("utf-8")
        new_text = rewrite_paths(text)
        if new_text != text:
            html.write_text(new_text, "utf-8")
            count += 1

    # 4. Generate static landing page → docs/index.html
    items = discover_dashboards()
    (DST / "index.html").write_text(render_landing(items), "utf-8")

    # 5. .nojekyll (sonst frisst Jekyll _shared/)
    (DST / ".nojekyll").touch()

    # Hidden meta files don't need rewriting; we leave .meta.json as-is

    total_files = sum(1 for _ in DST.rglob("*") if _.is_file())
    print(f"✓ Built {DST.relative_to(ROOT)}/")
    print(f"  · {len(items)} dashboards")
    print(f"  · {count} HTML files with path rewrites")
    print(f"  · {total_files} total files")
    print(f"  · Pages source: branch=main path=/docs")


if __name__ == "__main__":
    main()
