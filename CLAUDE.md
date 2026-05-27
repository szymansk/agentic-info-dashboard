# Projekt-Kontext für Claude

Du bist in `ai-news-dashboard` — einem lokalen Multi-Dashboard-Server für
AI/Agentic-AI-Themen. Die Inhalte werden teils manuell, teils automatisch
über eine Background-Claude-Session aktualisiert.

## Architektur in 30 Sekunden

```
.
├── serve.py                    # stdlib-Webserver, Threading, kein Reverse-DNS
├── install.sh                  # Setup auf frischem System (systemd + firewall)
├── DAILY_UPDATE.md             # Orchestrator-Prompt für die Background-Session
├── bin/
│   ├── start-daily-loop.sh     # idempotenter Launcher (von systemd aufgerufen)
│   ├── loop.sh                 # Wrapper: status/log/attach/stop/restart
│   └── check.sh                # Health-Check
├── scripts/
│   └── fetch-youtube.py        # täglicher RSS-Crawl der YT-Channels
└── dashboards/
    ├── _shared/people.js       # einzige Quelle für Personen-Daten + Tooltips
    ├── ai-news/                # Tagesbriefing (täglich neu, mit Archive)
    ├── youtube/                # Hot Videos (täglich frisch via Cron)
    ├── whoiswho/               # Top 20 Köpfe (manuelle Pflege)
    └── sources/                # Quellen-Sammlung (manuelle Pflege)
```

## Update-Verantwortlichkeiten

| Dashboard | Update-Quelle | Frequenz |
|---|---|---|
| `/ai-news/` | Claude Background-Session via `DAILY_UPDATE.md` | täglich (`/loop 24h`) |
| `/ai-news/` Snapshots | dieselbe Session, archiviert gestern beim heutigen Lauf | täglich |
| `/youtube/` | `scripts/fetch-youtube.py` via systemd-Timer | täglich 06:00 |
| `/whoiswho/` | manuell, editiere `dashboards/_shared/people.js` | bei Bedarf |
| `/sources/` | manuell, editiere `dashboards/sources/index.html` | bei Bedarf |

## Konventionen

- **Sprache**: alle Inhalte deutsch, Tooling-Kommentare englisch oder deutsch
- **Stil im Briefing**: analytisch, opinionated, kein Hype — Vorbild
  Stratechery + Bloomberg Tech
- **Fonts**: NUR System-Fonts, niemals Google-Fonts einbinden (langsam,
  Datenschutz)
- **JS-Strings mit deutschen Zitaten**: schließendes Anführungszeichen MUSS
  `"` (U+201D) sein, nicht ASCII `"`. Sonst bricht der String-Literal.
  Siehe `memory/feedback_german_quotes_in_js.md` falls vorhanden.
- **Snapshots**: jeder Archive-HTML-Snapshot hat `data-snapshot-mode="archive"`;
  die Live-Version `data-snapshot-mode="live"`. Sed-Ersetzung präzise machen
  (nur das body-Tag, nicht CSS-Selektoren).
- **People-Mentions**: Personen-Namen in Briefing/Cards mit
  `<span data-person="<slug>">...</span>` umschließen. Tooltips greifen
  automatisch. Slugs aus `dashboards/_shared/people.js`.
- **Verifikations-Regel**: nach jedem grösseren Edit `bin/check.sh` laufen
  lassen (oder die in `DAILY_UPDATE.md` Section 6 beschriebenen Checks).

## Systemd-Units (alle in /etc/systemd/system/)

| Unit | Type | Wann |
|---|---|---|
| `ai-news-dashboard.service` | simple | beim Boot, hält den Server am Leben |
| `ai-news-dashboard-youtube-fetch.service` | oneshot | vom Timer aufgerufen |
| `ai-news-dashboard-youtube-fetch.timer` | timer | täglich 06:00 |
| `ai-news-dashboard-daily-loop.service` | oneshot+RemainAfterExit | beim Boot, sichert Background-Session |

## Background-Session-Mechanik

Die Claude-Background-Session läuft `/loop 24h` und arbeitet die
`DAILY_UPDATE.md` täglich ab. Sie wird beim Reboot **NICHT** automatisch
fortgeführt (Background-Sessions überleben Shutdown nicht — siehe
[Docs](https://code.claude.com/docs/en/agent-view#how-background-sessions-are-hosted)).
Stattdessen läuft `bin/start-daily-loop.sh` beim Boot via systemd und
startet die Session bei Bedarf neu (idempotent).

State-Dateien der Background-Session liegen unter:
- `~/.claude/daemon/roster.json` — Liste der Sessions
- `~/.claude/jobs/<id>/state.json` — pro-Session-State
- `~/.claude/daemon.log` — Supervisor-Log

Inspect:
- `./bin/loop.sh status` — Name, ID, PID, Alter (Convenience-Wrapper)
- `./bin/loop.sh log` — Logs ANSI-gestrippt + lesbar
- `./bin/loop.sh attach` — in die Session wechseln (← detachen)
- `claude daemon status` — Supervisor-State
- `claude agents` — interaktive Übersicht
- `claude logs <short-id>` — direkter Zugriff (Name funktioniert NICHT, nur ID)

Die Session legt beim ersten `/loop` einen persistenten **Cron-Job** an (via
`CronCreate`-Tool), der täglich triggert. Der Cron-Job überlebt
Session-Sleep + Idle-Stops. Auflisten: `claude /cron list` innerhalb einer
attached Session.

## Was ich (Claude) hier NICHT tun soll

- Browser-Cache-Probleme als Bug behandeln, bevor `bin/check.sh` Pass ist
- `dashboards/_shared/people.js` ändern, ohne nach dem Schreiben
  `python3 -c "import ast; ..."` für sane-Check der Quoting laufen zu lassen
  (siehe Memory)
- Mehrere `systemd`-Units in einem `sudo`-Call schreiben — User wird sonst
  zweimal nach Passwort gefragt
- Snapshot-Archive löschen — das ist die historische Timeline
- Auto-Commit (Repo hat keinen Git-Ursprung, soll lokal bleiben)

## Wo finde ich was

- **Aktuelles Briefing**: `dashboards/ai-news/index.html` (live)
- **Gestriges Briefing**: `dashboards/ai-news/archive/<gestern>.html`
- **Timeline-Index**: `dashboards/ai-news/archive/manifest.json`
- **YouTube-Daten**: `dashboards/youtube/data.json` (vom Script erzeugt)
- **Personen-Stammdaten**: `dashboards/_shared/people.js`
- **Quellen-Liste**: `dashboards/sources/index.html`
- **Logs**: `journalctl -u ai-news-dashboard*`
- **Health**: `./bin/check.sh`
