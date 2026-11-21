# agentic-info-dashboard

Multi-Dashboard für AI/Agentic-AI-News.

- **Live**: https://szymansk.github.io/agentic-info-dashboard/
- **Lokal**: `python3 serve.py` → http://localhost:8000/

Ein Python-Webserver serviert lokal mehrere Dashboards aus `./dashboards/`.
Updates laufen automatisch über systemd-Timer: YouTube per RSS-Crawl, das
Tagesbriefing und die Wochenseiten per `claude -p`-Oneshot (`bin/run-daily.sh`).
`bin/deploy.sh` baut den statischen Pages-Output (`docs/`) und pusht nach jedem
Update. Ein Watchdog und ein GitHub-Workflow melden Ausfälle.

## Quickstart auf einem frischen System

```bash
git clone … agentic-info-dashboard
cd agentic-info-dashboard

# Secrets vorab anlegen (nur für Daily/Weekly nötig)
claude setup-token            # im Browser bestätigen, Token wird angezeigt
bin/set-token.sh              # Token einfügen, Enter, Ctrl-D → ~/.config/ai-news-dashboard/daily.env
$EDITOR ~/.config/ai-news-dashboard/alert.env   # CALLMEBOT_PHONE/CALLMEBOT_APIKEY und/oder NTFY_TOPIC

./install.sh                  # als normaler User, NICHT mit sudo (ruft sudo selbst)
```

Das Setup-Skript:
1. prüft Voraussetzungen (`python3`, `systemctl`, `claude`) und die Env-Dateien
2. rendert systemd-Units mit korrekten Pfaden + User
3. installiert + aktiviert Webserver, YouTube-Timer, Daily-/Weekly-Oneshot, Watchdog
4. öffnet den Port in firewalld (falls aktiv)
5. fetcht initial die YouTube-Daten
6. läuft `bin/check.sh` zur Verifikation

**Optional via Environment-Variablen:**
- `PORT=9000` — Webserver-Port (Default 8000)
- `SKIP_FIREWALL=1` — kein firewalld-Eintrag
- `SKIP_DAILY=1` — ohne Daily-/Weekly-Oneshot und Watchdog

Env-Dateien: Format `KEY=wert`, Kommentare nur als ganze Zeilen, keine
Shell-Sonderzeichen im Wert. Sie gehören nie ins Repo.

## Voraussetzungen

| Tool | Wozu | Notwendig |
|---|---|---|
| Python ≥ 3.9 | Webserver, Fetch- und Build-Skript | **ja** |
| systemd | Services + Timer | **ja** |
| sudo | Unit-Installation, Firewall | **ja** |
| firewalld | LAN-Zugang | optional |
| `claude` (Claude Code) | Tagesbriefing + Wochenseiten | optional |

Keine Python-Pakete erforderlich — stdlib only.

## Struktur

```
.
├── install.sh                    # ein-Befehl-Setup auf neuem System
├── serve.py                      # Webserver (ThreadingHTTPServer, Auto-Discovery)
├── DAILY_UPDATE.md               # Prompt für den täglichen claude -p-Lauf
├── WEEKLY_UPDATE.md              # Prompt für den Wochenlauf
├── CLAUDE.md                     # Kontext + Runbook für Claude-Sessions
├── specs/, plans/                # Design-Specs und Implementierungspläne
├── bin/
│   ├── run-daily.sh              # Tages-/Wochenlauf (JOB=daily|weekly)
│   ├── lib-daily.sh              # gemeinsame Helfer (nur sourcen)
│   ├── verify-briefing.sh        # Ergebnisprüfung Tagesbriefing
│   ├── verify-pages.sh           # Ergebnisprüfung Wochenseiten
│   ├── alert.sh                  # Alarmweg (CallMeBot / ntfy / Journal)
│   ├── watchdog.sh               # alle 30 min: Frische, Token, Pages, YouTube
│   ├── set-token.sh              # Setup-Token nach daily.env
│   ├── verify-daily.sh           # Units einmal per systemd auslösen
│   ├── deploy.sh                 # build-pages → commit → push
│   └── check.sh                  # Health-Check
├── scripts/
│   ├── fetch-youtube.py          # YT-RSS-Crawl
│   └── build-pages.py            # dashboards/ → docs/ mit Pfad-Rewriting
├── tests/                        # Bash-Tests für bin/ (run-all.sh)
├── dashboards/
│   ├── _shared/people.js         # Personen-Stammdaten + Tooltip-Logik
│   ├── ai-news/                  # Tagesbriefing + archive/ (Snapshots, manifest.json)
│   ├── it-services/              # IT-Services-Radar
│   ├── youtube/                  # Hot Videos (data.json vom Skript)
│   ├── regulation/, coding-tools/, calendar/, extensions/   # Wochenseiten
│   ├── whoiswho/                 # Top 20 Köpfe
│   └── sources/                  # Quellen-Sammlung
└── docs/                         # Build-Output für GitHub Pages (eingecheckt)
```

`bin/start-daily-loop.sh`, `loop.sh`, `verify-daily-loop.sh` und
`fix-selinux-launcher.sh` stammen aus dem abgelösten Background-Session-Betrieb
und werden zurückgebaut.

## Update-Verantwortlichkeiten

| Dashboard | Update-Mechanik | Frequenz |
|---|---|---|
| `/ai-news/` Tagesbriefing + Archiv | `ai-news-dashboard-daily.timer` → `bin/run-daily.sh` → `claude -p` (`DAILY_UPDATE.md`) | täglich 07:15, Retry 2 h, max. 3/Tag |
| `/it-services/` | derselbe Tageslauf | täglich |
| `/youtube/` | `scripts/fetch-youtube.py` via systemd-Timer | täglich 06:00 + 13:00 |
| `/regulation/`, `/coding-tools/`, `/calendar/`, `/extensions/` | `ai-news-dashboard-weekly.timer` → `JOB=weekly bin/run-daily.sh` (`WEEKLY_UPDATE.md`) | So 13:30 |
| `/whoiswho/`, `/sources/` | manuell editieren | bei Bedarf |

## Aktualisierung von Hand

```bash
# YouTube sofort updaten
python3 scripts/fetch-youtube.py
sudo systemctl start ai-news-dashboard-youtube-fetch.service   # oder via Unit

# Tageslauf (idempotent: steht das heutige Briefing schon, Exit 0)
bin/run-daily.sh --dry-run                 # nur Preflight + Entscheidung
sudo systemctl start ai-news-dashboard-daily.service
sudo systemctl reset-failed ai-news-dashboard-daily.service
bin/run-daily.sh --reset-attempts          # sonst zählt der Handstart als Versuch

# Wochenlauf
JOB=weekly bin/run-daily.sh </dev/null

# Pages-Output bauen + pushen
./bin/deploy.sh "custom commit message"

# Health-Check
./bin/check.sh
```

## Tests

```bash
bash tests/run-all.sh          # alle Tests
bash tests/test-classify.sh    # einzelner Test
./bin/verify-daily.sh          # Units einmal echt per systemd auslösen
bin/alert.sh --test            # Alarmkanäle testen
```

Die Tests laufen in einer Sandbox mit eigenem State-Verzeichnis und Stubs für
`claude`, `curl`, `systemctl` und `gh` — sie fassen weder echten State noch das
Netz an.

## GitHub Pages

- URL: https://szymansk.github.io/agentic-info-dashboard/
- Source: branch `main`, folder `/docs`
- Build via `scripts/build-pages.py`: kopiert `dashboards/` → `docs/` und
  schreibt absolute Pfade `/foo` zu `/agentic-info-dashboard/foo` um.
- `docs/` ist eingecheckt; `bin/deploy.sh` wird automatisch von der
  YouTube-Fetch-Unit (`ExecStartPost`) und am Ende von `DAILY_UPDATE.md`
  aufgerufen.
- Archiv-Snapshots, `manifest.json` und `youtube/data.json` sind in
  `dashboards/` gitignored und persistieren nur über ihre Kopie in `docs/`.

## Überwachung

- **Alarme**: jede Unit hat `OnFailure=ai-news-dashboard-alert@…`; Zustellung
  über `bin/alert.sh` (CallMeBot, ntfy, Journal), höchstens alle 12 h pro Vorfall.
- **Watchdog** (alle 30 min): Frische von Briefing und Wochenseiten, Token,
  Pages-Stand, YouTube.
- **Extern**: GitHub-Workflow `stale-check` mailt, wenn Pages bis zum
  Nachmittag kein heutiges Briefing zeigt.

```bash
systemctl status ai-news-dashboard            # Webserver
systemctl list-timers 'ai-news-dashboard-*'   # nächste Timer-Termine
journalctl -u ai-news-dashboard-daily -n 40   # Tageslauf
journalctl -t ai-news-alert                   # Alarme
cat ~/.local/state/ai-news-dashboard/last-run.json
```

Die Bedeutung der einzelnen Alarme (`AUTH`, `DIRTY`, `REPO`, `QUALITY`,
`GIVEUP` …) und was zu tun ist, steht im Runbook in `CLAUDE.md`.

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

- Webserver: startet automatisch (systemd `WantedBy=multi-user.target`)
- Alle Timer (YouTube, Daily, Weekly): verpasste Termine werden nachgeholt
  (`Persistent=true`)

## Troubleshooting

| Problem | Lösung |
|---|---|
| Dashboard zeigt alte Daten | erst `./bin/check.sh`, dann Hard-Reload im Browser (Ctrl-Shift-R) |
| Briefing nicht aktualisiert | `./bin/check.sh` (Sektion „daily run”), `journalctl -u ai-news-dashboard-daily -n 40` |
| Alarm `AUTH` / `TOKEN` | `claude setup-token` → `bin/set-token.sh` |
| Alarm `DIRTY` | fremde Änderungen im Working Tree committen oder stashen |
| YouTube leer | `journalctl -u ai-news-dashboard-youtube-fetch -n 30` |
| Port nicht erreichbar | `bin/check.sh` und `firewall-cmd --list-all` |
| Browser sieht keine Tooltips | JS-Console öffnen — wahrscheinlich Syntax-Error in `people.js` |
