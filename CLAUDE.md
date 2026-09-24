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
├── DAILY_UPDATE.md             # Prompt für den täglichen claude -p-Oneshot
├── specs/                      # Design-Specs
├── plans/                      # Implementierungspläne
├── .github/workflows/stale-check.yml # externer Wächter (Pages-Datum)
├── bin/
│   ├── run-daily.sh            # Tageslauf: claude -p + Klassifikation + Verify + Cleanup
│   ├── verify-briefing.sh      # Ergebnisprüfung (--pre-deploy im Prompt, --full im Wrapper)
│   ├── alert.sh                # einziger Alarmweg (CallMeBot/ntfy/Journal)
│   ├── watchdog.sh             # alle 30 min: Frische, Token, Pages, YouTube
│   ├── set-token.sh            # Setup-Token nach ~/.config/ai-news-dashboard/daily.env
│   ├── verify-daily.sh         # Units einmal per systemd auslösen
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
- am Ende von `DAILY_UPDATE.md` Step 7 (täglicher `claude -p`-Oneshot, s. Tageslauf-Mechanik)
- manuell wenn du sofort live haben willst

## Update-Verantwortlichkeiten

| Dashboard | Update-Quelle | Frequenz |
|---|---|---|
| `/ai-news/` | systemd-Timer 07:15 → `bin/run-daily.sh` → `claude -p` (`DAILY_UPDATE.md`) | täglich |
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
| `ai-news-dashboard-daily.timer/.service` | timer → oneshot | täglich 07:15, Retry 2 h, max. 3/Tag |
| `ai-news-dashboard-alert@.service` | oneshot (Template) | von `OnFailure` der Units |
| `ai-news-dashboard-watchdog.timer/.service` | timer → oneshot | alle 30 min, nur Alarme |

## Tageslauf-Mechanik (seit 2026-09, systemd-Oneshot)

`ai-news-dashboard-daily.timer` startet 07:15 `bin/run-daily.sh`, das `claude -p`
mit `DAILY_UPDATE.md` ausführt (Token aus `~/.config/ai-news-dashboard/daily.env`,
nur in dieser Prozessumgebung). Design und Begründung: `specs/2026-09-24-daily-run-oneshot-design.md`.

**Runbook**
- Zustand: `./bin/check.sh` (Sektion „daily run"), `journalctl -u ai-news-dashboard-daily -n 40`,
  `journalctl -t ai-news-alert`, `~/.local/state/ai-news-dashboard/last-run.json`
- Lauf von Hand: `sudo systemctl start ai-news-dashboard-daily.service` (idempotent: steht das
  heutige Briefing schon, Exit 0). Danach `sudo systemctl reset-failed …` + `bin/run-daily.sh --reset-attempts`,
  sonst zählen Handstarts als Versuche.
- Alarm `AUTH`/`TOKEN`/`TOKEN_LIVE`: `claude setup-token` im Browser → `bin/set-token.sh` (Token per stdin).
- Alarm `DIRTY`: fremde Änderungen im Working Tree committen oder stashen; der Lauf fasst nur
  `dashboards/ai-news`, `dashboards/it-services`, `docs` an.
- Alarm `GIVEUP`/`STUCK`-artige Fälle: Grund steht in der Nachricht und in `last-failure.daily`;
  Transcript des Laufs: `~/.claude/projects/<slug>/<session_id>.jsonl` (`session_id` in `last-run.json`).
- Alarm `REPO`: `git status -sb`, `git log --oneline -3 origin/main` — von Hand rebasen/pushen.
- Alarm `QUALITY`: Briefing ist deployt, aber dünn/kaputt (Grund in der Nachricht); Schwellen in
  `daily.env` (`MIN_WORDS`, `MIN_CARDS`), Prüfung selbst: `bin/verify-briefing.sh --full`.
- Alarm `PUBLIC_STALE`: Pages hinkt — `gh run list`, GitHub-Pages-Status; lokal ist alles ok.
- Kein Alarm, aber Briefing alt: GitHub-Workflow `stale-check` mailt spätestens 18:17 CEST;
  `gh run list --workflow stale-check.yml`.
- Testkette (nach Änderungen an Units/Skripten): `bash tests/run-all.sh`, `./bin/verify-daily.sh`,
  `bin/alert.sh --test`.

**Historie (Background-Session, Mai–September 2026)**: Vier stille Ausfälle (Upgrade-Kill
29.05., Idle-Exit + Modell 15.06., SELinux + PATH 01.07., Auth-Ablauf + blinder Selbstheiler
11.07.–24.09.) führten zur Ablösung. Details und Lehren: Spec Abschnitt 2 und
`git log -- bin/start-daily-loop.sh`.

## Was ich (Claude) hier NICHT tun soll

- Browser-Cache-Probleme als Bug behandeln, bevor `bin/check.sh` Pass ist
- `claude …`-Output mit `grep -q` unter `set -o pipefail` prüfen — Output erst
  in eine Variable capturen, dann grep (sonst EPIPE → Fehlalarm)
- `dashboards/_shared/people.js` ändern, ohne nach dem Schreiben
  `python3 -c "import ast; ..."` für sane-Check der Quoting laufen zu lassen
  (siehe Memory)
- Mehrere `systemd`-Units in einem `sudo`-Call schreiben — User wird sonst
  zweimal nach Passwort gefragt
- Snapshot-Archive löschen — das ist die historische Timeline
- `docs/` von Hand editieren — das ist Build-Output, immer via `build-pages.py`
- absolute Pfade `/foo` in Edits durch transformierte Pfade ersetzen —
  Source-HTMLs nutzen IMMER `/foo`, build-pages.py macht das Rewriting
- `~/.config/ai-news-dashboard/*.env` ins Repo oder in Logs bringen (Secrets)
- `ai-news-dashboard-daily.service` von Hand starten, ohne danach `reset-failed` + `--reset-attempts`

## Wo finde ich was

- **Aktuelles Briefing**: `dashboards/ai-news/index.html` (live)
- **Gestriges Briefing**: `dashboards/ai-news/archive/<gestern>.html`
- **Timeline-Index**: `dashboards/ai-news/archive/manifest.json`
- **YouTube-Daten**: `dashboards/youtube/data.json` (vom Script erzeugt)
- **Personen-Stammdaten**: `dashboards/_shared/people.js`
- **Quellen-Liste**: `dashboards/sources/index.html`
- **Logs**: `journalctl -u ai-news-dashboard*`
- **Health**: `./bin/check.sh`
- **Watchdog-Alarme**: `journalctl -t ai-news-alert`, `~/.local/state/ai-news-dashboard/{alerts.log,last-alert,last-run.json}`
- **Tageslauf-Transcript**: `~/.claude/projects/-home-szymansk-Projects-agentic-info-dashboard/<session_id>.jsonl`
