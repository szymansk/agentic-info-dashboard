# agentic-info-dashboard

Multi-Dashboard für AI/Agentic-AI-News.

- **Live**: https://szymansk.github.io/agentic-info-dashboard/
- **Lokal**: `python3 serve.py` → http://localhost:8000/

Ein Python-Webserver serviert lokal mehrere Dashboards aus `./dashboards/`.
Tägliche Updates laufen automatisch (YouTube via systemd-Timer, Tagesbriefing
via Claude Code Background-Session mit `/loop`). `bin/deploy.sh` baut den
statischen Pages-Output (`docs/`) und pusht nach jedem Update.

## Quickstart auf einem frischen System

```bash
git clone … ai-news-dashboard
cd ai-news-dashboard
./install.sh
```

Das Setup-Skript:
1. prüft Voraussetzungen (`python3`, `claude`, `systemctl`)
2. rendert systemd-Units mit korrekten Pfaden + User
3. installiert + aktiviert Webserver, YouTube-Timer, Daily-Loop
4. öffnet den Port in firewalld (falls aktiv)
5. fetcht initial die YouTube-Daten
6. läuft `bin/check.sh` zur Verifikation

**Optional via Environment-Variablen:**
- `PORT=9000` — Webserver-Port (Default 8000)
- `SKIP_FIREWALL=1` — kein firewalld-Eintrag
- `SKIP_DAILY_LOOP=1` — keine Claude Background-Session aufsetzen

## Voraussetzungen

| Tool | Wozu | Notwendig |
|---|---|---|
| Python ≥ 3.9 | Webserver + Fetch-Skript | **ja** |
| systemd | Services + Timer | **ja** |
| sudo | Unit-Installation, Firewall | **ja** |
| firewalld | LAN-Zugang | optional |
| `claude` (Claude Code) | Daily-Briefing-Auto-Update | optional |

Keine Python-Pakete erforderlich — stdlib only.

## Struktur

```
.
├── install.sh                    # ein-Befehl-Setup auf neuem System
├── serve.py                      # Webserver (ThreadingHTTPServer)
├── DAILY_UPDATE.md               # Orchestrator-Prompt für die Background-Session
├── CLAUDE.md                     # Kontext für künftige Claude-Sessions
├── bin/
│   ├── start-daily-loop.sh       # idempotenter Launcher (vom systemd aufgerufen)
│   └── check.sh                  # Health-Check
├── scripts/
│   └── fetch-youtube.py          # täglicher YT-RSS-Crawl
└── dashboards/
    ├── _shared/people.js         # Personen-Stammdaten + Tooltip-Logik
    ├── ai-news/                  # Tagesbriefing
    │   ├── index.html
    │   ├── .meta.json
    │   └── archive/              # tägliche Snapshots
    │       └── manifest.json     # Timeline-Daten
    ├── youtube/                  # Hot Videos
    │   ├── index.html
    │   ├── data.json             # vom Skript erzeugt
    │   └── .meta.json
    ├── whoiswho/                 # Top 20 Köpfe (Profile)
    └── sources/                  # Quellen-Sammlung
```

## Update-Verantwortlichkeiten

| Dashboard | Update-Mechanik | Frequenz |
|---|---|---|
| `/ai-news/` Tagesbriefing | Claude Background-Session via `/loop 24h` | täglich |
| `/ai-news/` Archive | Background-Session beim Tagesupdate | täglich |
| `/youtube/` | `scripts/fetch-youtube.py` via systemd-Timer | täglich 06:00 |
| `/whoiswho/`, `/sources/` | manuell editieren | bei Bedarf |

## Aktualisierung von Hand

```bash
# YouTube sofort updaten
python3 scripts/fetch-youtube.py

# oder via Service-Trigger
sudo systemctl start ai-news-dashboard-youtube-fetch.service

# Daily-Loop starten / neu aufsetzen
./bin/start-daily-loop.sh

# Pages-Output bauen + pushen (manuell)
./bin/deploy.sh "custom commit message"

# Health-Check
./bin/check.sh
```

## GitHub Pages

- URL: https://szymansk.github.io/agentic-info-dashboard/
- Source: branch `main`, folder `/docs`
- Build via `scripts/build-pages.py`: kopiert `dashboards/` → `docs/` und
  schreibt absolute Pfade `/foo` zu `/agentic-info-dashboard/foo` um.
- `docs/` ist eingecheckt; `bin/deploy.sh` wird automatisch von der
  YouTube-Fetch-Unit (`ExecStartPost`) und am Ende von `DAILY_UPDATE.md`
  aufgerufen.

## Server-Verwaltung

```bash
systemctl status ai-news-dashboard            # Webserver
systemctl list-timers ai-news-dashboard-*     # nächste Timer-Termine
journalctl -u ai-news-dashboard-youtube-fetch -n 20

# Claude Background-Session (daily-ai-update)
./bin/loop.sh status                           # Name, ID, PID, Alter
./bin/loop.sh log                              # Logs ANSI-gestrippt + lesbar
./bin/loop.sh attach                           # in die Session wechseln
./bin/loop.sh restart                          # stop + neu starten

# Raw via claude CLI
claude agents                                  # interaktive Agent-View
claude daemon status                           # Supervisor-Status
claude logs <short-id>                         # logs braucht die ID, nicht den Namen
                                               # (./bin/loop.sh id liefert sie)
```

## Neues Dashboard hinzufügen

1. `dashboards/<slug>/index.html` anlegen
2. Optional `dashboards/<slug>/.meta.json` daneben:
   ```json
   {
     "title": "Mein neues Dashboard",
     "description": "Was es zeigt.",
     "tag": "Kategorie",
     "accent": "#6ec38b"
   }
   ```
3. Landing-Page reloaden — Karte erscheint automatisch (Auto-Discovery
   anhand `index.html`-Vorkommen)

## Reboot-Verhalten

- Webserver: ✓ startet automatisch (systemd `WantedBy=multi-user.target`)
- YouTube-Timer: ✓ verpasste Termine werden nachgeholt (`Persistent=true`)
- Daily-Loop: ✓ `start-daily-loop.sh` läuft beim Boot und stellt sicher,
  dass die Background-Session existiert

Claude-Code-Background-Sessions überleben Shutdown nicht (siehe
[Docs](https://code.claude.com/docs/en/agent-view#how-background-sessions-are-hosted)).
Der Launcher startet die Session bei Bedarf neu.

## Troubleshooting

| Problem | Lösung |
|---|---|
| Dashboard zeigt alte Daten | Hard-Reload im Browser (Ctrl-Shift-R) |
| YouTube leer | `journalctl -u ai-news-dashboard-youtube-fetch -n 30` |
| Daily-Loop läuft nicht | `./bin/start-daily-loop.sh` von Hand + `claude logs daily-ai-update` |
| Port nicht erreichbar | `bin/check.sh` und `firewall-cmd --list-all` |
| Browser sieht keine Tooltips | JS-Console öffnen — wahrscheinlich Syntax-Error in `people.js` |
