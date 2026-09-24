# Design: Tageslauf als systemd-Oneshot (`claude -p`) statt Background-Session

Datum: 2026-09-24 · Version 2 (nach zwei unabhängigen Reviews) · Status: zur
Bestätigung durch die Reviewer, dann Implementierungsplan

## 1. Ziel

Der tägliche Briefing-Lauf des ai-news-dashboards soll über Monate unbeaufsichtigt
laufen, ohne still stehen zu bleiben. Wenn er doch scheitert, erfährt Marc es **am
selben Tag** per WhatsApp, mit Grund und Handlungsanweisung. Ein Ausfall darf nie
still sein: jede Prüfung, die auf der Maschine läuft, hat ein externes Gegenstück.

**Nicht-Ziele**: Inhalt und Qualität des Briefings ändern; ein Web-UI für Betrieb;
Multi-User.

## 2. Ausgangslage

Vier Ausfälle in vier Monaten (Mai–September 2026), jeder in einer anderen Schicht
der Background-Session-Mechanik (`claude --bg` + `/loop 24h` + Supervisor-Daemon):

| Datum | Ursache | Stillstand |
|---|---|---|
| 29.05. | Binary-Auto-Upgrade killt Supervisor, kommt nicht zurück | 6 Tage |
| 15.06. | Idle-Exit des Daemons + Healthcheck-Timer nie aktiviert + Default-Modell unverfügbar | 8 Tage |
| 01.07. | SELinux blockt Launcher-Exec (203) + PATH ohne `~/.local/bin` | 6 Tage |
| 11.07. | OAuth-Refresh-Token (28 Tage) abgelaufen; Session-Cron gibt auf; Selbstheiler blind (nur Mechanik) und kaputt (`grep -q` + pipefail, `daemon stop` ohne `--any`) | 75 Tage |

Gemeinsamer Nenner: ein langlebiger Prozess, der überleben muss; Überwachung, die
den Mechanismus statt das Ergebnis misst; kein Alarmkanal. Der parallel laufende
YouTube-Fetch (systemd-Timer → Oneshot-Skript) ist in derselben Zeit nie ausgefallen.

Seit 24.09. überbrückt ein ergebnisbasierter Watchdog (`bin/start-daily-loop.sh`)
die Session-Mechanik. Dieses Design ersetzt sie.

## 3. Entscheidungen

| Frage | Entscheidung |
|---|---|
| Architektur | systemd-Timer → Oneshot-Service → `claude -p`. Kein Daemon, keine Session, die überleben muss. |
| Umsetzungsform | systemd-nativ (Retry, Startlimit, OnFailure in Units); schlanke Bash-Skripte mit eingebettetem Python für JSON. |
| Auth | Langlebiger Token aus `claude setup-token` (1 Jahr), nur in der Prozessumgebung der Units. Interaktiver Login bleibt getrennt. |
| Alarmierung | CallMeBot (WhatsApp) als Pflichtkanal, ntfy optional als zweiter, healthchecks.io als externer Dead-Man-Switch (empfohlen, braucht ein Konto). Claude-Code-Push nur als Testpunkt. WhatsApp-Channel-Plugin optional in Phase 5. |
| Fehlerfall | Lauf entscheidet konservativ selbst. Wiederholbare Fehler: bis zu 2 Wiederholungen im Abstand von 2 h, danach Alarm. Nicht-wiederholbare Fehler: sofort Alarm, kein Retry. Nach jedem Fehlschlag räumt der Wrapper die Reste des eigenen Laufs weg, damit der Retry sauber startet. |

## 4. Architektur

```
06:00   youtube-fetch.timer → youtube-fetch.service (TimeoutStartSec=10min, OnFailure→alert)
          → fetch-youtube.py → ExecStartPost: deploy.sh
07:15   daily.timer (Persistent) → daily.service (oneshot, After=youtube-fetch)
          └─ bin/run-daily.sh
               0. Binary + Env laden (daily.env, alert.env)      Token fehlt → 3
               1. Lock (flock)                                    belegt → 9
               2. git fetch + ff-only                             diverged → 9, Netz → 5
               3. Dirt klassifizieren                             eigener Dirt → stash+weiter · fremder → 4
               4. Idempotenz: Briefing heute?                     gepusht → 0 · nur ahead → push-only
               5. Manifest sichern, healthchecks /start
               6. claude -p --output-format json … (rc capturen)  trap TERM → cleanup, 5
               7. JSON klassifizieren                             401/403→3 · 400/404/Budget→8 · BLOCKED→7 · sonst→5
               8. verify-briefing.sh (Inhalt, Archiv, Manifest, docs/, gepusht)   → 6 (nicht deployt) · 10 (deployt, aber mangelhaft)
               9. Pages-URL bis 10 min pollen (nur Warnung), last-run.json, healthchecks Ping
        Fehler → systemd: Restart=on-failure, RestartSec=2h, StartLimitBurst=3 (Fenster 8 h)
        4. Start abgelehnt ODER RestartPreventExitStatus → failed → OnFailure → alert@ai-news-dashboard-daily.service
*:00/30 watchdog.timer → watchdog.service (OnFailure→alert) → bin/watchdog.sh
          pending-Alarme nachsenden · Token-Restlaufzeit · STALE (lokal + Pages-URL) · YouTube-Alter
          · daily.service failed (neue InvocationID) · gh auth · So: Token-Live-Check + Lebenszeichen
extern  healthchecks.io: erwartet täglich einen Ping, Grace 30 h → E-Mail/Telegram, unabhängig von der Maschine
```

Jeder Lauf ist ein eigener Prozess mit Journal-Log (`journalctl -u ai-news-dashboard-daily`)
und eigener Transcript-Datei (`claude -p --resume <session_id>` zum Nachlesen).

## 5. Komponenten

### 5.1 systemd-Units (Vorlagen in `install.sh`, installiert nach `/etc/systemd/system/`)

Kein `EnvironmentFile`: Die Skripte laden ihre Env-Dateien selbst (bash `source`,
wie heute `start-daily-loop.sh`). Damit gibt es nur ein Dateiformat, systemd (PID 1)
muss nichts unter `/home` lesen, und eine fehlende Datei lässt die Alert-Unit nicht
mitsterben, sondern degradiert `alert.sh` auf Journal.

**`ai-news-dashboard-daily.timer`**: `OnCalendar=*-*-* 07:15:00`, `Persistent=true`.

**`ai-news-dashboard-daily.service`**:

```ini
[Unit]
Description=Daily AI news briefing (claude -p oneshot)
After=network-online.target ai-news-dashboard-youtube-fetch.service
Wants=network-online.target
OnFailure=ai-news-dashboard-alert@%p.service
StartLimitIntervalSec=8h
StartLimitBurst=3

[Service]
Type=oneshot
User=szymansk
Group=szymansk
WorkingDirectory=/home/szymansk/Projects/agentic_info_dashboard
Environment=DISABLE_AUTOUPDATER=1 GIT_TERMINAL_PROMPT=0 GH_NO_UPDATE_NOTIFIER=1
StandardInput=null
ExecStart=/home/szymansk/Projects/agentic_info_dashboard/bin/run-daily.sh
TimeoutStartSec=90min
Restart=on-failure
RestartSec=2h
RestartPreventExitStatus=3 4 8 9 10
InaccessiblePaths=-/home/szymansk/.ssh
```

Semantik (systemd 259, per `systemd-analyze verify` und Man-Pages geprüft):

- Oneshot mit `Restart=on-failure` ist erlaubt; `TimeoutStartSec` begrenzt die
  Laufzeit; bei Ablauf SIGTERM → das Skript fängt es (trap) und räumt auf.
- Die Unit betritt `failed` (und löst `OnFailure` aus) **bei Ablehnung des vierten
  Starts** durch das Startlimit, nicht nach dem dritten Fehler. Bei Fehlern um
  07:15, 09:15, 11:15 kommt der Alarm also gegen 13:15 (Worst Case mit drei
  90-min-Timeouts: 17:45). Nicht-wiederholbare Exit-Codes führen sofort zu `failed`.
- `After=youtube-fetch` bleibt: es serialisiert die beiden `Persistent`-Nachholstarts
  nach einem Boot (sonst zwei parallele Git-Commits). Dafür bekommt die YouTube-Unit
  ein Timeout (unten), damit ein hängender Fetch den Tageslauf nicht unbegrenzt blockiert.
- `StartLimitIntervalSec=8h` statt 18 h: Ein manueller Start am Vorabend zählt sonst
  ins Fenster und kostet einen Versuch. Nach Tests: `systemctl reset-failed`.
- `DISABLE_AUTOUPDATER=1`: kein Binary-Wechsel mitten im Lauf (Upgrades kommen laut
  `daemon.log` fast täglich zwischen 22:00 und 04:00 UTC).
- `InaccessiblePaths=-/home/szymansk/.ssh`: der Lauf braucht kein SSH (Remote ist HTTPS,
  Push über `gh auth git-credential`). Härtung von `~/.claude/.credentials.json` wird
  in der Generalprobe getestet (könnte das CLI stören), siehe Phase 5.
- Ein Reboot während `auto-restart` verwirft den ausstehenden Retry; `Persistent`
  holt nur den 07:15-Zeitpunkt nach. Akzeptiert.

**`ai-news-dashboard-alert@.service`** (Template; Instanz `%i` = Präfix der
gescheiterten Unit, z. B. `ai-news-dashboard-daily`): `Type=oneshot`,
`StandardInput=null`, `ExecStart=bin/alert.sh unit-failed %i`.

**`ai-news-dashboard-watchdog.timer/.service`**: `OnCalendar=*-*-* *:00/30:00`
(feste Raster statt `OnUnitActiveSec`, damit Wochenfenster nicht driften),
`ExecStart=bin/watchdog.sh`, `OnFailure=ai-news-dashboard-alert@%p.service`.
Ersetzt `healthcheck.timer/.service`.

**`ai-news-dashboard-youtube-fetch.service`** (neu gerendert): `ReadWritePaths=$PROJECT_DIR`
(installiert ist derzeit nur `dashboards/youtube`, womit ein Deploy an `docs/` und
`.git/` scheitern würde), `TimeoutStartSec=10min` (der Fetch hängt laut Memory
gelegentlich; Oneshot-Default ist unendlich), `ExecStartPost=bin/deploy.sh`,
`OnFailure=ai-news-dashboard-alert@%p.service`, `Environment=GIT_TERMINAL_PROMPT=0 GH_NO_UPDATE_NOTIFIER=1`.
`ProtectHome=read-only` bleibt; `gh` liest `~/.config/gh/hosts.yml`. Ob `gh` beim
Push nach `~/.config/gh` schreiben will, klärt die Generalprobe (dann `ReadWritePaths`
ergänzen).

**Entfernt**: `ai-news-dashboard-daily-loop.service`, `ai-news-dashboard-healthcheck.timer/.service`.

**SELinux**: Verzeichnisregel `semanage fcontext -a -t bin_t "$PROJECT_DIR/bin(/.*)?"`
(idempotent: `-a || -m`), `restorecon -R bin/`. Die alte Datei-Regel für
`start-daily-loop.sh` wird in Phase 4 mit `-d` entfernt. `deploy.sh` und `install.sh`
machen `restorecon -R bin/`. Der Exec-Pfad `init_t` → `bin_t` → `unconfined_service_t`
ist heute bewiesen (Healthcheck läuft so). Verworfen: `ExecStart=/usr/bin/bash <skript>`
als Umgehung, weil unbelegt, ob `init_t` ein `user_home_t`-Skript lesen darf.

### 5.2 `bin/run-daily.sh`

Aufruf durch systemd oder von Hand (`</dev/null`, sonst wartet `claude -p` 3 s auf stdin);
`--dry-run` zeigt Preflight und Entscheidung; `DAILY_ENV=<pfad>` überschreibt die
Env-Datei (für Fehlerinjektion).

| Schritt | Verhalten | Exit |
|---|---|---|
| Binary | `~/.local/bin/claude` zuerst, dann PATH; fehlt → | 5 |
| Env | `daily.env` + `alert.env` sourcen; `CLAUDE_CODE_OAUTH_TOKEN` leer → | 3 |
| Lock | `flock -n` auf `$STATE_DIR/run.lock`; belegt (paralleler Hand-/Timerstart) → | 9 |
| Repo | verwaistes `.git/index.lock` (älter als 1 h) entfernen; `git fetch origin` (Netz weg → 5); `git merge --ff-only origin/main` bei sauberem Tree; divergiert → | 9 |
| Dirt | `git status --porcelain --untracked-files=all`, Pfade klassifizieren. Eigener Dirt (`dashboards/ai-news/`, `dashboards/it-services/`, `docs/`) = Reste eines abgebrochenen Laufs oder YouTube-Deploys → `git stash push -u -m "daily-leftover <ts>"` + Journal-Warnung, weiter. Fremder Dirt (alles andere) → | 4 |
| Idempotenz | `data-snapshot-date` == heute: gepusht (`git status -sb` ohne „ahead") → 0 ohne Lauf. Nur ahead → **push-only**: `git push`; Erfolg → 0, Netz/5xx → 6, non-fast-forward → 9. Kein Modell-Lauf. | 0/6/9 |
| Sicherung | `manifest.json` nach `$STATE_DIR/manifest.bak`; Liste der Archivdateien; healthchecks `/start`-Ping (falls konfiguriert). | |
| Lauf | `rc=0; claude -p --output-format json --model "$CLAUDE_MODEL" [--fallback-model "$FALLBACK_MODEL"] --dangerously-skip-permissions --strict-mcp-config --disallowedTools AskUserQuestion --max-budget-usd "$MAX_BUDGET_USD" "$PROMPT" >"$OUT" </dev/null \|\| rc=$?`. stderr → Journal. `trap` auf TERM/INT: Cleanup, `last-failure=TIMEOUT`, Exit 5. | |
| Klassifikation | JSON parsen (kein JSON → 5). Felder: `is_error`, `terminal_reason`, `api_error_status`, optional `result`, `permission_denials`, `total_cost_usd`, `session_id`. `api_error_status` 401/403 → 3 · 400/404 oder `terminal_reason=budget_exhausted` → 8 · `result` enthält Zeile `BLOCKED:` → 7 · sonstiger `is_error` (429, 5xx, Netz) → 5. `permission_denials` nicht leer → Journal-Warnung. | 3/5/7/8 |
| Ergebnis | `bin/verify-briefing.sh` (5.3). Nicht deployt (Datum alt, dirty, ahead) → 6. Deployt, aber inhaltlich mangelhaft → Alarm `QUALITY` direkt aus dem Skript + | 6/10 |
| Abschluss | Pages-URL bis 10 min auf heutiges Datum pollen (nur Warnung; der Watchdog übernimmt `PUBLIC_STALE`). `last-run.json`: Zeit, Dauer, Exit, `total_cost_usd`, `num_turns`, `session_id`, `claude --version`, `STATUS:`-Zeile. healthchecks-Ping `/` bzw. `/fail`. | 0 |
| Cleanup bei Exit ≠ 0 | Reste des Laufs sichern: `git stash push -u -m "daily-fail <ts> exit <n>"` für `dashboards/ai-news dashboards/it-services docs`; `manifest.json` aus Sicherung zurück; neue Archivdateien bleiben (harmlos, Schritt 4 im Prompt ist idempotent). | |

Exit-Codes und Retry:

| Code | Bedeutung | Retry |
|---|---|---|
| 0 | erfolgreich, heute schon erledigt, oder push-only erfolgreich | – |
| 3 | AUTH: Token fehlt oder 401/403 | nein |
| 4 | DIRTY: fremde Änderungen im Working Tree | nein |
| 5 | RUN: transient (Binary fehlt, kein JSON, 429/5xx, Netz, Timeout) | ja |
| 6 | OUTCOME: kein frisches, gepushtes Briefing (auch push-only mit Netzfehler) | ja |
| 7 | BLOCKED: Lauf meldet Blockade | ja |
| 8 | API: nicht-transient (Modell unbekannt 400/404, Budget erschöpft) | nein |
| 9 | REPO: Lock belegt, divergiert, non-fast-forward | nein |
| 10 | QUALITY: deployt, aber Prüfung mangelhaft (Alarm direkt aus dem Skript) | nein |

Gemessen (CLI 2.1.281): `claude -p` liefert bei Fehlern **Exit 1** und ein JSON auf
stdout (`is_error:true`, `terminal_reason:"api_error"`, `api_error_status:401`); bei
erschöpftem Budget `subtype:"error_max_budget_usd"`, `terminal_reason:"budget_exhausted"`
und **kein `result`-Feld**; bei Erfolg Exit 0, `terminal_reason:"completed"`. Der
Wrapper darf deshalb nie auf `set -e` für den Aufruf vertrauen, muss `subtype`
ignorieren und ein fehlendes `result` tolerieren. WebSearch funktioniert im
`-p`-Modus (Probelauf des Reviewers). `--bare` wird nicht verwendet (liest keine
OAuth-Credentials).

### 5.3 `bin/verify-briefing.sh`

Gemeinsame Ergebnisprüfung für den Wrapper und Schritt 6 in `DAILY_UPDATE.md`.
Argument `--date <YYYY-MM-DD>` (Default heute; der Wrapper übergibt das Startdatum
des Laufs, damit ein Nachhollauf über Mitternacht nicht scheitert).

| Prüfung | Fehlerklasse |
|---|---|
| `data-snapshot-date` in `dashboards/ai-news/index.html` und `docs/ai-news/index.html` ≥ Startdatum | nicht deployt |
| Tree clean, nichts ahead (nach `git fetch`) | nicht deployt |
| `.briefing-wrap` ≥ 800 Wörter; ≥ 3 Breaking-Cards mit externen Links auf ≥ 2 Domains; Briefing-Text nicht identisch mit dem vorherigen Snapshot | mangelhaft |
| Vorheriger Live-Snapshot existiert jetzt unter `archive/<datum>.html` mit `data-snapshot-mode="archive"` | mangelhaft |
| `manifest.json` valides JSON; genau ein Eintrag mit `url: /ai-news/` und heutigem Datum; keine doppelten Daten; nur Felder `date/url/headline/summary` | mangelhaft |

### 5.4 `bin/alert.sh`

Schnittstelle: `alert.sh <ART> <Text…>`, `alert.sh unit-failed <unit>` (liest
`$STATE_DIR/last-failure`, sonst Journal-Ende der Unit), `alert.sh --resend`
(pending-Alarme), `alert.sh --test`, Option `--force` (Drosselung aus). Sourced nur
`alert.env`; fehlt sie → nur Journal + Statusdatei, Exit 0.

1. Journal: `logger -p user.err -t ai-news-alert "[ART] Text"`.
2. Statusdateien: `alerts.log` (Historie), `last-alert` (für `check.sh`; wird vom nächsten Exit-0-Lauf gelöscht).
3. Drosselung **pro Vorfall** (Hash aus ART + erste 80 Zeichen Text), 12 h. FAILED aus dem Watchdog nur, wenn kein Unit-Alarm < 12 h; STALE nur, wenn kein Unit-Alarm < 24 h.
4. CallMeBot: `curl -fsS -m 20 -G https://api.callmebot.com/whatsapp.php --data-urlencode phone=… --data-urlencode apikey=… --data-urlencode text=…`. Antwort muss „queued" enthalten.
5. ntfy (falls `NTFY_TOPIC`/`NTFY_URL` gesetzt): `curl -d`.
6. Stempel für die Drosselung **nur bei erfolgreicher Zustellung** auf mindestens einem Kanal. Sonst `pending-alerts` schreiben; der Watchdog sendet alle 30 min nach.

Nachrichten sind kurz, mit Grund und nächstem Schritt:
`⛔ ai-news: Token ungültig (401). Fix: bin/set-token.sh nach claude setup-token` ·
`⚠ ai-news: Lauf 3× gescheitert (RUN: 529 overloaded). Nächster Versuch morgen 07:15` ·
`⚠ ai-news: Briefing deployt, aber nur 412 Wörter (QUALITY). journalctl -u ai-news-dashboard-daily`.

### 5.5 `bin/watchdog.sh`

Alle 30 min, nur Prüfung und Alarm, keine Reparatur. `--dry-run` zeigt alle Werte,
`check.sh` nutzt das.

| Prüfung | Alarm |
|---|---|
| `pending-alerts` vorhanden | `alert.sh --resend` |
| `TOKEN_CREATED` + 365 d − heute ≤ 14 d | TOKEN, täglich |
| Sonntag (ISO-Wochenstempel): Live-Check `claude -p 'OK' --model claude-haiku-4-5-20251001 --max-turns 1` mit dem Unit-Token | TOKEN_LIVE bei Fehler |
| Lokales Briefing: Alter ≥ 1 Tag **und** Uhrzeit ≥ 14:00, oder Alter ≥ 2 | STALE, 12 h |
| Pages-URL: `data-snapshot-date` ≠ lokal, länger als 60 min nach `last-run.json` | PUBLIC_STALE, 12 h |
| `dashboards/youtube/data.json` älter als 30 h | YOUTUBE, 12 h |
| `daily.service` `failed` mit InvocationID ≠ zuletzt alarmierter | FAILED (Sicherheitsnetz) |
| `gh auth status` schlägt fehl | GH_AUTH, täglich |
| Sonntag, `HEARTBEAT=1`, Wochenstempel | „✅ ai-news lebt. Briefing <Datum>, letzter Lauf <Zeit>, Token live ok, noch <n> Tage" |

### 5.6 Env-Dateien (`~/.config/ai-news-dashboard/`, Verzeichnis 700, Dateien 600, nie im Repo)

Format = bash-`source`-kompatibel: `KEY=wert`, keine Leerzeichen um `=`, **keine
Kommentare hinter Werten** (nur ganze Zeilen mit `#`), keine `$`-Expansion.
`install.sh` prüft das und bricht bei Verstoß ab.

`daily.env` (jährlich angefasst):

```
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-…
TOKEN_CREATED=2026-09-24
CLAUDE_MODEL=claude-opus-4-8
FALLBACK_MODEL=
MAX_BUDGET_USD=30
```

`alert.env` (stabil; heute schon mit CallMeBot-Werten angelegt):

```
CALLMEBOT_PHONE=49…
CALLMEBOT_APIKEY=…
NTFY_TOPIC=
HEALTHCHECKS_URL=
HEARTBEAT=1
```

`bin/set-token.sh` schreibt Token und `TOKEN_CREATED` gemeinsam (liest den Token von
stdin, nie als Argument). Der Token ist bewusst nicht in `~/.claude/settings.json`:
global gesetzt würde er Remote Control der interaktiven Sessions blockieren
(Issue #96076). Die Datei liegt im Home und damit in Home-Backups; akzeptiert.

### 5.7 `DAILY_UPDATE.md`

- Neue Sektion „Betriebsmodus: unbeaufsichtigt" nach der Einleitung: keine Rückfragen
  (`AskUserQuestion` ist ohnehin gesperrt), konservativ entscheiden, bei echter Blockade
  Zeile `BLOCKED: <Grund>` ausgeben und aufhören.
- Schritt 0 Idempotenz: **`data-snapshot-date` in `index.html` == heute** → STOP mit
  Meldung. (Die bisherige Prüfung auf `archive/<heute>.html` greift am selben Tag nie,
  weil heute erst morgen archiviert wird.)
- Schritt 4 Archivierung idempotent: existiert `archive/<vorheriges Datum>.html` und
  der Manifest-Eintrag, überspringen, kein zweiter Eintrag.
- Schritt 6 Verifikation ruft `bin/verify-briefing.sh`.
- Schritt 8: Bilanz als Zeile mit Marker `STATUS: …` (der Personen-Vorschlag aus
  Schritt 3 darf danach folgen; der Wrapper greppt den Marker).
- `/loop`-Bezüge (Zeilen 4 und 270) entfernt.

### 5.8 `bin/deploy.sh`

`git add dashboards docs` statt `git add -A`: nur generierte Inhalte gelangen in
Briefing-Commits. Das beendet auch das dokumentierte „Session sammelt fremde Edits
ein" und verkleinert, was ein manipulierter Lauf ins öffentliche Repo schreiben
könnte. `restorecon -R bin/` statt Einzeldatei.

### 5.9 `bin/check.sh`

Sektion „daily run": letzter Lauf aus `last-run.json` (Zeit, Exit, Dauer, Kosten,
`STATUS:`), Zustand von `daily.service` inklusive `activating (auto-restart)` und
nächstem Timer-Start, `watchdog.service` Result/ExecMainStatus, Watchdog-`--dry-run`,
letzter Alarm, Token-Restlaufzeit, `gh auth status`. Ein abgelaufener interaktiver
Login ist nach der Migration kein Fehler mehr (nur Hinweis).

### 5.10 `install.sh`

Reihenfolge: `sudo -v` zuerst (ein Passwort-Prompt); Env-Dateien vorhanden und
formatgültig, Token gesetzt (sonst Abbruch mit Anleitung); alte Units `disable --now`
+ `reset-failed` + Dateien löschen; SELinux-Verzeichnisregel + `restorecon -R bin/`;
Units mit `$PROJECT_DIR`/`$HOME` des Run-Users rendern; `systemd-analyze verify`;
`install` + `daemon-reload`; Timer `enable --now`. Alles unter einem `sudo`-Timestamp.

## 6. Sicherheit

- Secrets nur in `~/.config/ai-news-dashboard/*.env` (600) und in der Prozessumgebung
  der Units. Kein `set -x`, kein `curl -v` in Skripten, die sie sourcen. Fehlerinjektion
  nur über Test-Env-Dateien, nie `--setenv` (sichtbar in `systemctl show`).
- Der Token gilt nur für die Units; interaktive Sessions nutzen den Keychain-Login.
- Der Lauf liest fremde Webseiten mit Bash-Vollzugriff als `szymansk`
  (`--dangerously-skip-permissions` bleibt nötig). Erreichbar wären Env-Token,
  `~/.config/gh/hosts.yml` (Token mit `repo`+`workflow`-Scope), `~/.claude/.credentials.json`.
  Gegenmaßnahmen jetzt: `--strict-mcp-config` (kein fremder MCP-Server), `git add`
  mit Pathspec, `InaccessiblePaths` für `~/.ssh`. Optional in Phase 5: repo-scoped
  Fine-grained-PAT per `LoadCredential=` statt `gh`-Token, `~/.claude/.credentials.json`
  unzugänglich machen (Test nötig).
- CallMeBot ist ein Drittanbieter („personal use only"): Nachrichten enthalten keine
  Secrets und keine URLs mit Keys. Der Dienst meldet „queued" auch, wenn WhatsApp
  nicht zustellt; deshalb Lebenszeichen, zweiter Kanal und externer Dead-Man-Switch.
- Phase 5 (Channel-Plugin): Community-Software mit verknüpftem Gerät, Allowlist nur
  Marcs Nummer, nur in interaktiven Sessions.

## 7. Migration und Rückbau

| Phase | Wer | Schritte | Ergebnis |
|---|---|---|---|
| 0 Vorbereitung | Marc | `claude setup-token` im Browser → `bin/set-token.sh`; optional healthchecks.io-Check anlegen (Grace 30 h, E-Mail) und URL in `alert.env` | Auth für Oneshot vorhanden |
| 1 Bauen | Claude | `run-daily.sh`, `verify-briefing.sh`, `alert.sh`, `watchdog.sh`, `set-token.sh`, Unit-Vorlagen, `install.sh`, `deploy.sh`, `DAILY_UPDATE.md`, `check.sh`, Tests, Doku | Alles committet; alte Session läuft weiter |
| 2 Umschalten | Marc + Claude | `sudo ./install.sh`; `alert.sh --test`; dann alte Session beenden: `./bin/loop.sh attach` → `/cron list` → Eintrag löschen → `claude stop <sid>`. Alte Skripte bleiben als manueller Notfallweg. | Neue Units aktiv, kein Doppelbetrieb am ersten Echtlauf |
| 3 Generalprobe | beide | a) `sudo systemctl start ai-news-dashboard-daily.service` an einem Tag mit fertigem Briefing → Exit 0 idempotent; danach `reset-failed`. b) Fehlerinjektion: `DAILY_ENV=test.env bin/run-daily.sh </dev/null` mit ungültigem Token → Exit 3, `alert.sh` direkt → WhatsApp „401" kommt an (transiente Units haben kein `OnFailure`). c) Erster Echtlauf am Folgetag 07:15 beobachten (`journalctl -f`). d) YouTube-Deploy um 06:00 aus der gehärteten Unit prüfen (Push, `gh`-Schreibzugriff). e) `--setting-sources project` testen; falls `-p` ohne User-Settings sauber läuft, übernehmen. | Kanal, Retry, Deploy verifiziert |
| 4 Rückbau | Claude | `start-daily-loop.sh`, `loop.sh`, `verify-daily-loop.sh`, `fix-selinux-launcher.sh` löschen; `semanage fcontext -d` für die alte Datei-Regel; CLAUDE.md: Session-Abschnitte durch Runbook ersetzen, alte Failure-Modes als „Historie"; Memory; in frischer interaktiver Session `/cron list` prüfen (projektgebundene Scheduler-Lock `.claude/scheduled_tasks.lock`) | Kein Session-Code mehr |
| 5 Optional | Marc + Claude | WhatsApp-Channel-Plugin (Allowlist, Test); Fine-grained-PAT per `LoadCredential`; `InaccessiblePaths` für Credentials | Statusabfragen vom Handy, engere Rechte |

## 8. Tests

- `tests/test-run-daily.sh`: JSON-Klassifikation mit Fixtures (Erfolg; 401; 404;
  `budget_exhausted` ohne `result`; `result` mit `BLOCKED:`; kein JSON) und
  Dirt-Klassifikation (eigen/fremd) gegen ein temporäres Git-Repo. Läuft ohne Netz
  und ohne Token (`run-daily.sh --classify <datei>`, `--classify-dirt`).
- `tests/test-verify-briefing.sh`: Fixtures für gutes Briefing, Datum-only-Update,
  doppelter Manifest-Eintrag, fehlendes Archiv.
- `run-daily.sh --dry-run`, `watchdog.sh --dry-run`, `alert.sh --test`.
- `bin/verify-daily.sh`: löst `daily.service` und `watchdog.service` per systemd aus,
  prüft Result, ExecMainStatus, Journal; ersetzt `verify-daily-loop.sh`.
- Fehlerinjektion (Phase 3b) mit Test-Env-Datei.

## 9. Annahmen und Risiken

| Annahme | Absicherung |
|---|---|
| Tools (WebSearch, WebFetch, Bash, Edit) im `-p`-Modus wie in der Session | WebSearch per Probelauf belegt; Rest in 3a/3c; Fallback `--allowedTools` |
| Ablaufdatum des Setup-Tokens lokal nicht lesbar (`claude auth status` zeigt nur `authMethod`) | `TOKEN_CREATED` via `set-token.sh`, Warnung ab 351 Tagen, sonntäglicher Live-Check |
| CallMeBot kann ausfallen, pausieren („Stop") oder „queued" ohne Zustellung melden | Lebenszeichen, ntfy, healthchecks.io |
| Claude-Code-Push im `-p`-Modus ungeprüft | Testpunkt in Phase 3; kein Pflichtkanal |
| `gh` unter `ProtectHome=read-only` beim Push | Phase 3d; ggf. `ReadWritePaths` um `~/.config/gh` |
| Modell `claude-opus-4-8` bleibt verfügbar; Kosten pro Lauf unbekannt | `CLAUDE_MODEL`/`FALLBACK_MODEL` per Env; Kosten ab dem ersten Lauf in `last-run.json`; 400/404 alarmieren sofort |
| Alarm frühestens ~13:15 bei drei wiederholbaren Fehlern | akzeptiert („am selben Tag"); STALE-Regel ≥ 14:00 als Netz |

## 10. Änderungen nach Review (Version 2)

Zwei unabhängige Reviews (technisch mit Man-Pages und Probeläufen; adversarial auf
Ausfallarten). Übernommen:

- **Retry war wirkungslos**: Jeder Fehler nach dem ersten Edit hinterließ einen dirty
  Tree → Exit 4 ohne Retry. Jetzt: eigener Dirt wird gestasht, fremder alarmiert;
  Cleanup per trap auch bei Timeout.
- **Doppel-Briefing**: Push-Fehler nach Commit hätte einen zweiten vollen Lauf mit
  doppeltem Archiv/Manifest ausgelöst. Jetzt: push-only-Pfad; Schritt 0 und 4 im
  Prompt idempotent; Alt-Session wird in Phase 2 gestoppt, nicht erst in Phase 4.
- **Exit-Code-Annahme falsch**: `claude -p` liefert bei Fehlern Exit 1 (nicht 0);
  Budget-Fehler ohne `result`. Wrapper capturet `rc`, klassifiziert über
  `is_error`/`terminal_reason`/`api_error_status`.
- **YouTube-Unit**: Timeout 10 min (sonst blockiert ein hängender Fetch den Tageslauf
  unbegrenzt über `After=`), `ReadWritePaths` auf das Repo, `OnFailure`. HTTPS/`gh`
  statt der falschen SSH-Annahme.
- **Kein `EnvironmentFile`**: Skripte sourcen die Env selbst; ein Dateiformat, keine
  PID-1-Leserechte unter `/home`, Alert-Unit stirbt nicht mit.
- **Alarm-Zustellung**: Stempel nur bei Erfolg, `pending`-Nachsenden, Drosselung pro
  Vorfall, ntfy bleibt, externer Dead-Man-Switch (healthchecks.io) empfohlen.
- **Falsche Erfolgsmeldung**: `verify-briefing.sh` prüft Inhalt, Archiv, Manifest,
  `docs/`; Pages-URL-Check; STALE schon am selben Tag ab 14:00.
- **Nicht-transiente Fehler** (Modell weg, Budget) ohne Retry (Exit 8); `--fallback-model`
  optional; `DISABLE_AUTOUPDATER=1`; `--strict-mcp-config`; `--disallowedTools AskUserQuestion`.
- Kleineres: `StartLimitIntervalSec=8h`, Watchdog auf `OnCalendar`-Raster,
  `STATUS:`-Marker, `StandardInput=null`, `set-token.sh`, `git add` mit Pathspec,
  `install.sh`-Reihenfolge, `semanage -a || -m`, OnFailure-Zeitpunkt dokumentiert.

Verworfen mit Begründung:

- `ExecStart=/usr/bin/bash <skript>` zur SELinux-Umgehung: unbelegt, ob `init_t` das
  Skript lesen darf; die Verzeichnisregel ist der bewiesene Pfad.
- `After=youtube-fetch` streichen: serialisiert die Nachholstarts nach Boot; das
  Timeout an der YouTube-Unit löst das eigentliche Problem.
- Env-Datei nach `/etc` (root): unnötig, sobald die Skripte selbst sourcen; Bearbeitung
  ohne sudo bleibt möglich.

## 11. Quellen

- CallMeBot WhatsApp-API: <https://www.callmebot.com/blog/free-api-whatsapp-messages/>
- Claude Code Headless-Doku (Exit-Codes, JSON): <https://code.claude.com/docs/en/headless>
- Claude Code Auth-Doku (Token-Vorrang, Setup-Token): <https://code.claude.com/docs/en/authentication>
- `setup-token` und Remote Control bei globalem Env: <https://github.com/anthropics/claude-code/issues/96076>
- Headless `claude -p` ohne Refresh-Pfad: <https://github.com/anthropics/claude-code/issues/79685>
- Claude Code WhatsApp-Channel-Plugins (Community): <https://github.com/rich627/whatsapp-claude-plugin>, <https://github.com/diogo85/claude-code-whatsapp>
- healthchecks.io (Dead-Man-Switch): <https://healthchecks.io/>
- Meta WhatsApp Cloud API (verworfen, zu schwer): <https://wexio.io/blog/free-whatsapp-business-api>
