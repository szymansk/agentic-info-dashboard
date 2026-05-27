#!/usr/bin/env python3
"""
Dashboard server.

Serves every subdirectory of ./dashboards/ that contains an index.html
and auto-generates a landing page that lists them.

Usage:
    python3 serve.py            # port 8000
    python3 serve.py 9000       # custom port

Drop new dashboards in:
    dashboards/<slug>/index.html
    dashboards/<slug>/.meta.json   (optional: title, description, tag, accent)
"""

import http.server
import json
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DASHBOARDS_DIR = ROOT / "dashboards"
DEFAULT_PORT = 8000


def discover_dashboards():
    items = []
    if not DASHBOARDS_DIR.exists():
        return items
    for entry in sorted(DASHBOARDS_DIR.iterdir(), key=lambda p: p.name.lower()):
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


def render_index():
    items = discover_dashboards()
    now = datetime.now().strftime("%A, %d. %B %Y · %H:%M")

    if not items:
        body = (
            '<div class="empty">'
            '<h2>Noch keine Dashboards</h2>'
            '<p>Lege ein Dashboard in <code>dashboards/&lt;slug&gt;/index.html</code> ab '
            'und lade neu.</p>'
            '</div>'
        )
    else:
        cards = []
        for d in items:
            cards.append(
                f'''<a class="card" href="/{d['slug']}/" style="--accent:{d['accent']}">
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

    return f"""<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Dashboards</title>
<style>
  :root {{
    --bg: #0b0d12;
    --panel: #161a24;
    --panel-2: #1b2030;
    --line: #232a3a;
    --text: #e7ecf3;
    --muted: #8b94a8;
    --dim: #5d6577;
    --accent: #7aa2f7;
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
    min-height: 100vh;
    line-height: 1.55;
  }}
  code {{ font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; color: var(--muted); }}
  a {{ color: inherit; text-decoration: none; }}

  .wrap {{ max-width: 1180px; margin: 0 auto; padding: 40px 28px 80px; }}
  header {{
    display: flex; align-items: baseline; justify-content: space-between;
    gap: 24px; margin-bottom: 32px;
    padding-bottom: 22px; border-bottom: 1px solid var(--line);
  }}
  header h1 {{
    margin: 0; font-size: 28px; font-weight: 800; letter-spacing: -.02em;
  }}
  header .sub {{ color: var(--muted); font-size: 14px; margin-top: 4px; }}
  header .meta {{
    color: var(--muted); font-size: 12px; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
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
    border: 1px solid var(--line);
    border-radius: 14px;
    transition: transform .12s ease, border-color .12s ease, background .12s ease;
    overflow: hidden;
  }}
  .card::before {{
    content: ""; position: absolute; left: 0; top: 0; bottom: 0; width: 3px;
    background: var(--accent);
    opacity: .8;
  }}
  .card:hover {{ border-color: rgba(122,162,247,.45); transform: translateY(-1px); }}
  .card-head {{
    display: flex; justify-content: space-between; align-items: center;
    font-size: 11px; color: var(--dim); font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    letter-spacing: .04em; text-transform: uppercase;
  }}
  .card-tag {{
    color: var(--accent); border: 1px solid currentColor; padding: 1px 8px;
    border-radius: 999px; font-weight: 600; font-size: 10.5px;
    background: color-mix(in srgb, var(--accent) 8%, transparent);
  }}
  .card h2 {{
    margin: 4px 0 0; font-size: 17px; font-weight: 700; letter-spacing: -.005em;
  }}
  .card p {{ margin: 0; color: var(--muted); font-size: 13.5px; }}
  .card-arrow {{
    margin-top: auto; padding-top: 10px;
    font-size: 12px; color: var(--dim);
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  }}
  .card-arrow .chev {{ transition: transform .15s ease; display: inline-block; }}
  .card:hover .card-arrow {{ color: var(--accent); }}
  .card:hover .card-arrow .chev {{ transform: translateX(3px); }}

  .empty {{
    text-align: center; padding: 60px 20px; color: var(--muted);
    border: 1px dashed var(--line); border-radius: 14px;
  }}
  .empty h2 {{ margin: 0 0 10px; color: var(--text); font-weight: 700; }}

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
      <h1>📊 Dashboards</h1>
      <div class="sub">Lokal gehostet · {len(items)} Dashboard{'' if len(items) == 1 else 's'} verfügbar</div>
    </div>
    <div class="meta"><b id="now"></b></div>
  </header>
  {body}
  <footer>
    <div>Root: <code>./dashboards/</code></div>
    <div>Stopp: <code>Ctrl+C</code></div>
  </footer>
</div>
<script>
  const fmt = new Intl.DateTimeFormat('de-DE', {{
    weekday: 'long', day: '2-digit', month: 'long', year: 'numeric',
    hour: '2-digit', minute: '2-digit'
  }});
  document.getElementById('now').textContent = fmt.format(new Date());
</script>
</body>
</html>"""


class DashboardHandler(http.server.SimpleHTTPRequestHandler):
    # Disable reverse-DNS for every connection (this is the big latency killer).
    def address_string(self):
        return self.client_address[0]

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(DASHBOARDS_DIR), **kwargs)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            html = render_index().encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(html)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(html)
            return
        if self.path == "/favicon.ico":
            # Avoid a noisy 404 round-trip per page load.
            self.send_response(204)
            self.end_headers()
            return
        return super().do_GET()

    def log_message(self, fmt, *args):
        ts = datetime.now().strftime("%H:%M:%S")
        sys.stdout.write(f"  [{ts}] {self.address_string()} — {fmt % args}\n")


def main():
    port = DEFAULT_PORT
    if len(sys.argv) > 1:
        try:
            port = int(sys.argv[1])
        except ValueError:
            print(f"Invalid port: {sys.argv[1]}", file=sys.stderr)
            sys.exit(2)

    DASHBOARDS_DIR.mkdir(exist_ok=True)
    http.server.ThreadingHTTPServer.allow_reuse_address = True

    with http.server.ThreadingHTTPServer(("", port), DashboardHandler) as httpd:
        items = discover_dashboards()
        print()
        print(f"  ✨  Dashboard server")
        print(f"      URL:        http://localhost:{port}/")
        print(f"      Root:       {DASHBOARDS_DIR}")
        print(f"      Dashboards: {len(items)}")
        for d in items:
            print(f"        · /{d['slug']}/   ({d['title']})")
        print(f"      Stop:       Ctrl+C")
        print()
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\n  Server gestoppt.")


if __name__ == "__main__":
    main()
