# Projekt-Kontext für Claude

Du bist in `agentic-info-dashboard` — einem Multi-Dashboard für AI/Agentic-AI-
Themen. Lokal via `serve.py`, öffentlich via GitHub Pages
(**https://szymansk.github.io/agentic-info-dashboard/**). Inhalte werden teils
manuell, teils automatisch über eine Background-Claude-Session aktualisiert.

## Architektur in 30 Sekunden

```
.
├── serve.py                    # stdlib-Webserver für lokale Entwicklung
├── install.sh                  # Setup auf frischem System (systemd + firewall)
├── DAILY_UPDATE.md             # Orchestrator-Prompt für die Background-Session
├── bin/
│   ├── start-daily-loop.sh     # idempotenter Launcher (von systemd aufgerufen)
│   ├── loop.sh                 # Wrapper: status/log/attach/stop/restart
│   ├── deploy.sh               # build-pages → git commit → push
│   └── check.sh                # Health-Check
├── scripts/
│   ├── fetch-youtube.py        # täglicher RSS-Crawl der YT-Channels
│   └── build-pages.py          # baut docs/ für Pages (Pfad-Rewriting)
├── dashboards/                 # Source — lokal über serve.py
│   ├── _shared/people.js       # einzige Quelle für Personen-Daten + Tooltips
│   ├── ai-news/                # Tagesbriefing (täglich neu, mit Archive)
│   ├── youtube/                # Hot Videos (täglich frisch via Cron)
│   ├── whoiswho/               # Top 20 Köpfe (manuelle Pflege)
│   └── sources/                # Quellen-Sammlung (manuelle Pflege)
└── docs/                       # Build-Output für GitHub-Pages (eingecheckt)
```

## Veröffentlichung (GitHub Pages)

`scripts/build-pages.py` kopiert `dashboards/` → `docs/` und schreibt alle
absoluten Pfade `/foo` zu `/agentic-info-dashboard/foo` um (Sub-Path der
Pages-URL). `docs/` ist eingecheckt, Pages-Source = `main` branch, `/docs`
folder. `bin/deploy.sh` automatisiert den Zyklus build → commit → push.

Aufrufe von `deploy.sh`:
- nach `fetch-youtube.py` (via systemd ExecStartPost)
- am Ende von `DAILY_UPDATE.md` Step 7 (Background-Session)
- manuell wenn du sofort live haben willst

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

### Failure-Mode: Supervisor stirbt beim Binary-Auto-Upgrade

**Symptom**: Briefing aktualisiert sich tagelang nicht, aber YouTube (systemd-
Timer) läuft weiter. Ursache: Wenn der `claude`-Binary automatisch aktualisiert
wird, killt das den Supervisor-Daemon mid-uptime (`daemon.log`: „binary was
deleted — exiting for upgrade") und er kommt **NICHT von selbst zurück**. Die
Session wird zum Zombie: PID lebt noch, aber control.sock ist tot → keine
Cron-Wakeups, kein Auth-Refresh. Die Session produziert noch ein paar Tage aus
gecachten Credentials, dann stallt sie.

**Warum es nicht selbst heilte (früher)**: `daily-loop.service` lief nur beim
Boot; die Maschine wurde nicht neu gestartet. `start-daily-loop.sh` prüfte nur
`os.kill(pid, 0)` — die Zombie-PID lebt, also „alles gut".

**Fix (eingebaut)**:
- `start-daily-loop.sh` prüft jetzt zuerst `daemon_healthy()` und reapt via
  `claude daemon stop`, wenn der Supervisor weg ist → erzwingt Neustart.
- `ai-news-dashboard-healthcheck.timer` läuft alle 30 Min und ruft
  `start-daily-loop.sh` (heilt mid-uptime, nicht nur beim Boot).
- `bin/check.sh` zeigt Supervisor-Tod als roten `✗` + „Briefing veraltet".

**Manuelle Recovery** (falls doch mal nötig):
```bash
claude daemon stop          # reapt verwaiste Worker
./bin/start-daily-loop.sh   # startet frische Session (jetzt gehärtet)
./bin/check.sh              # verifizieren: daemon läuft + Briefing aktuell
```

### Failure-Mode: Briefing steht, Server läuft — zwei weitere Ursachen

Das Symptom „Briefing veraltet, aber YouTube/Server frisch" ist **nicht immer**
der Upgrade-Kill oben. Am 2026-06-23 stand das Briefing 8 Tage (seit 15.06.) —
zwei gestapelte Ursachen, die der Upgrade-Pfad nicht abdeckt:

1. **Idle-Exit statt Upgrade-Kill**: `daemon.log` zeigte
   `idle 5s with no clients — exiting` (KEIN „binary was deleted"). Der
   Supervisor beendete sich nach dem Tagesjob sauber, niemand startete neu.
   Der Selbstheiler `ai-news-dashboard-healthcheck.timer` war als Datei da,
   aber **`disabled` + `inactive`** — nie `systemctl enable --now`'d.
   → Timer-Aktiv-Status mitprüfen:
   `systemctl is-active ai-news-dashboard-healthcheck.timer`.

2. **Default-Modell unverfügbar**: Die neu gestartete Session erbte den
   interaktiven Default aus `~/.claude/settings.json` (`claude-fable-5`,
   Mythos-gated) und hing mit „Fable 5 is currently unavailable", statt zu
   arbeiten. Ein unbeaufsichtigter Loop darf NICHT vom interaktiven Default
   abhängen. → `start-daily-loop.sh` pinnt das Modell jetzt fest
   (`CLAUDE_MODEL="${CLAUDE_MODEL:-claude-opus-4-8}"` + `--model`).

**Diagnose-Reihenfolge** bei „Briefing veraltet, YouTube frisch":
```bash
claude daemon status                                    # Daemon tot?
systemctl is-active ai-news-dashboard-healthcheck.timer # Selbstheiler scharf?
./bin/loop.sh log | grep -iE "unavailable|fable|opus"   # Modell-Fehler?
```
Erst danach Upgrade-Kill annehmen — nicht zuerst.

## Was ich (Claude) hier NICHT tun soll

- Browser-Cache-Probleme als Bug behandeln, bevor `bin/check.sh` Pass ist
- `dashboards/_shared/people.js` ändern, ohne nach dem Schreiben
  `python3 -c "import ast; ..."` für sane-Check der Quoting laufen zu lassen
  (siehe Memory)
- Mehrere `systemd`-Units in einem `sudo`-Call schreiben — User wird sonst
  zweimal nach Passwort gefragt
- Snapshot-Archive löschen — das ist die historische Timeline
- `docs/` von Hand editieren — das ist Build-Output, immer via `build-pages.py`
- absolute Pfade `/foo` in Edits durch transformierte Pfade ersetzen —
  Source-HTMLs nutzen IMMER `/foo`, build-pages.py macht das Rewriting

## Wo finde ich was

- **Aktuelles Briefing**: `dashboards/ai-news/index.html` (live)
- **Gestriges Briefing**: `dashboards/ai-news/archive/<gestern>.html`
- **Timeline-Index**: `dashboards/ai-news/archive/manifest.json`
- **YouTube-Daten**: `dashboards/youtube/data.json` (vom Script erzeugt)
- **Personen-Stammdaten**: `dashboards/_shared/people.js`
- **Quellen-Liste**: `dashboards/sources/index.html`
- **Logs**: `journalctl -u ai-news-dashboard*`
- **Health**: `./bin/check.sh`
