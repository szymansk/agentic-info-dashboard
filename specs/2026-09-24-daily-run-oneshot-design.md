# Design: Tageslauf als systemd-Oneshot (`claude -p`) statt Background-Session

Datum: 2026-09-24 · Status: abgenommen (Brainstorming mit Marc) · Nächster Schritt: Implementierungsplan

## 1. Ziel

Der tägliche Briefing-Lauf des ai-news-dashboards soll über Monate unbeaufsichtigt
laufen, ohne still stehen zu bleiben. Wenn er doch scheitert, erfährt Marc es am
selben Tag per WhatsApp, mit Grund und Handlungsanweisung.

**Nicht-Ziele**: Inhalt und Qualität des Briefings ändern; die YouTube-Pipeline
umbauen; ein Web-UI für Betrieb; Multi-User.

## 2. Ausgangslage

Vier Ausfälle in vier Monaten (Mai–September 2026), jeder in einer anderen Schicht
der Background-Session-Mechanik (`claude --bg` + `/loop 24h` + Supervisor-Daemon):

| Datum | Ursache | Stillstand |
|---|---|---|
| 29.05. | Binary-Auto-Upgrade killt Supervisor, kommt nicht zurück | 6 Tage |
| 15.06. | Idle-Exit des Daemons + Healthcheck-Timer nie aktiviert + Default-Modell unverfügbar | 8 Tage |
| 01.07. | SELinux blockt Launcher-Exec (203) + PATH ohne `~/.local/bin` | 6 Tage |
| 11.07. | OAuth-Refresh-Token (28 Tage) abgelaufen; Session-Cron gibt auf; Selbstheiler blind (nur Mechanik) und kaputt (`grep -q` + pipefail, `daemon stop` ohne `--any`) | 75 Tage |

Gemeinsamer Nenner: Ein langlebiger Prozess, der überleben muss, plus Überwachung,
die den Mechanismus statt das Ergebnis misst, plus kein Alarmkanal. Der parallel
laufende YouTube-Fetch (systemd-Timer → Oneshot-Skript) ist in derselben Zeit nie
ausgefallen.

Seit 24.09. ist die Session-Mechanik mit einem ergebnisbasierten Watchdog
(`bin/start-daily-loop.sh`) überbrückt. Dieses Design ersetzt sie.

## 3. Entscheidungen (aus dem Brainstorming)

| Frage | Entscheidung |
|---|---|
| Architektur | Wechsel: systemd-Timer → Oneshot-Service → `claude -p`. Kein Daemon, keine Session, die überleben muss. |
| Umsetzungsform | systemd-nativ (Retry, Startlimit, OnFailure in Units), schlanke Bash-Skripte mit eingebettetem Python für JSON. |
| Auth | Langlebiger Token aus `claude setup-token` (1 Jahr), nur den Units per `EnvironmentFile` zugänglich. Interaktiver Login bleibt getrennt. |
| Alarmierung | CallMeBot (WhatsApp, unabhängig vom Claude-Login) als Pflichtkanal. Claude-Code-Push als Zusatz, sofern im `-p`-Modus verfügbar. WhatsApp-Channel-Plugin als optionale Phase 5 für Interaktion vom Handy. |
| Fehlerfall | Lauf entscheidet konservativ selbst. Wiederholbare Fehler: bis zu 2 automatische Wiederholungen im Abstand von 2 h, dann Alarm. Nicht-wiederholbare Fehler (Auth, unsauberer Tree): sofort Alarm. |

## 4. Architektur

```
06:00   youtube-fetch.timer → youtube-fetch.service → fetch-youtube.py → ExecStartPost deploy.sh
07:15   daily.timer → daily.service (oneshot, EnvironmentFile=watchdog.env)
          └─ bin/run-daily.sh
               1. Preflight   Token gesetzt? Working Tree clean? Briefing von heute schon gepusht → Exit 0
               2. Lauf        claude -p --output-format json --model … --dangerously-skip-permissions --max-budget-usd …
               3. Auswertung  is_error / api_error_status / "BLOCKED:" im Ergebnis
               4. Ergebnis    data-snapshot-date == heute · git clean · nichts ahead von origin/main
               5. State       ~/.local/state/ai-news-dashboard/last-run.json (Zeit, Exit, Kosten, Bilanz, session_id)
        Fehler → systemd: Restart=on-failure, RestartSec=2h, StartLimitBurst=3 (Fenster 18 h)
        Startlimit erreicht ODER RestartPreventExitStatus → OnFailure → alert@ai-news-dashboard-daily.service → bin/alert.sh
*/30    watchdog.timer → watchdog.service → bin/watchdog.sh
          Token-Restlaufzeit · Briefing-Alter ≥ 2 Tage · YouTube-Alter > 30 h · So 09:00 Lebenszeichen
```

Jeder Lauf ist ein eigener Prozess mit Journal-Log (`journalctl -u ai-news-dashboard-daily`)
und eigener Transcript-Datei (`claude -r <session_id>` zum Nachlesen).

## 5. Komponenten

### 5.1 systemd-Units (alle in `/etc/systemd/system/`, Vorlagen in `install.sh`)

**`ai-news-dashboard-daily.timer`**: `OnCalendar=*-*-* 07:15:00`, `Persistent=true`
(Nachholen nach Downtime; der idempotente Preflight macht das gefahrlos).

**`ai-news-dashboard-daily.service`**:

```ini
[Unit]
Description=Daily AI news briefing (claude -p oneshot)
After=network-online.target ai-news-dashboard-youtube-fetch.service
Wants=network-online.target
OnFailure=ai-news-dashboard-alert@%p.service
StartLimitIntervalSec=18h
StartLimitBurst=3

[Service]
Type=oneshot
User=szymansk
Group=szymansk
WorkingDirectory=/home/szymansk/Projects/agentic_info_dashboard
EnvironmentFile=/home/szymansk/.config/ai-news-dashboard/watchdog.env
ExecStart=/home/szymansk/Projects/agentic_info_dashboard/bin/run-daily.sh
TimeoutStartSec=90min
Restart=on-failure
RestartSec=2h
RestartPreventExitStatus=3 4
```

Semantik (systemd 259, per `systemd-analyze verify` geprüft): Oneshot mit `Restart=`
ist erlaubt; `TimeoutStartSec` begrenzt die Laufzeit des Oneshots; die Unit betritt
`failed` (und löst `OnFailure` aus) erst nach dem Startlimit, oder sofort bei
Exit-Codes aus `RestartPreventExitStatus`. Das 18-h-Fenster stellt sicher, dass drei
Versuche (07:15, 09:15, 11:15) den regulären Start am Folgetag nicht blockieren.

**`ai-news-dashboard-alert@.service`** (Template, Instanz = Präfix der gescheiterten
Unit via `%p`, also `ai-news-dashboard-daily`): `Type=oneshot`, gleiche `EnvironmentFile`, `ExecStart=bin/alert.sh unit-failed %i`.

**`ai-news-dashboard-watchdog.timer/.service`**: alle 30 min, `ExecStart=bin/watchdog.sh`,
gleiche `EnvironmentFile`. Ersetzt `healthcheck.timer/.service`.

**`ai-news-dashboard-youtube-fetch.service`**: bekommt das in der Vorlage schon
vorgesehene `ExecStartPost=bin/deploy.sh` (fehlt auf der Maschine). Hinweis: Die Unit
setzt `ProtectHome=read-only` + `ReadWritePaths=$PROJECT_DIR`; `git push` braucht
Lesezugriff auf `~/.ssh` (ok) und Schreibzugriff nur im Repo (ok). Wird in der
Generalprobe verifiziert.

**Entfernt**: `ai-news-dashboard-daily-loop.service`, `ai-news-dashboard-healthcheck.timer/.service`.

**SELinux**: Statt einer Datei-Regel eine Verzeichnis-Regel
`semanage fcontext -a -t bin_t "$PROJECT_DIR/bin(/.*)?"` + `restorecon -R bin/`.
`deploy.sh` macht `restorecon -R bin/` bei jedem Deploy (kein root nötig). Neue Skripte
brauchen damit keine eigene Regel.

### 5.2 `bin/run-daily.sh`

Aufruf durch systemd oder von Hand; `--dry-run` zeigt Preflight und Entscheidung.

| Schritt | Verhalten |
|---|---|
| claude-Binary | PATH-unabhängig auflösen (`~/.local/bin/claude` zuerst), wie heute. |
| Token | `CLAUDE_CODE_OAUTH_TOKEN` leer → Exit 3. Wird nie geloggt. |
| Working Tree | `git status --porcelain` nicht leer → Exit 4 (Deploy würde fremde Änderungen mit-pushen). |
| Idempotenz | `data-snapshot-date` == heute UND Tree clean UND `git status -sb` ohne „ahead" → Exit 0 ohne Lauf. |
| Lauf | `claude -p --output-format json --model "$CLAUDE_MODEL" --dangerously-skip-permissions --max-budget-usd "$MAX_BUDGET_USD" "$PROMPT"` mit `PROMPT` = „Du läufst unbeaufsichtigt als Oneshot ohne Rückfragemöglichkeit. Lies `DAILY_UPDATE.md` und führe den Workflow vollständig aus. Working directory ist …". stdout wird in eine Datei geschrieben (Journal bekommt Zusammenfassung), stderr ins Journal. |
| Auswertung | JSON parsen. `is_error` true oder `api_error_status` 401/403 → Exit 3 (Auth) bzw. 5 (sonstiger Laufzeitfehler). `result` beginnt mit oder enthält Zeile `BLOCKED:` → Exit 7. Die letzte Zeile von `result` (Status-Bilanz) ins Journal. |
| Ergebnis | Snapshot-Datum heute, Tree clean, nichts ahead → Exit 0; sonst Exit 6. |
| State | `last-run.json` und `last-failure` (Code + Grund) unter `~/.local/state/ai-news-dashboard/`. |

Exit-Codes:

| Code | Bedeutung | Retry |
|---|---|---|
| 0 | erfolgreich oder heute schon erledigt | – |
| 3 | AUTH: Token fehlt oder 401/403 | nein (sofort Alarm) |
| 4 | DIRTY: Working Tree nicht clean | nein (sofort Alarm) |
| 5 | RUN: `claude -p` meldet Fehler (Modell, Budget, Netz) | ja |
| 6 | OUTCOME: Lauf ohne frisches, gepushtes Briefing | ja |
| 7 | BLOCKED: Lauf meldet Blockade | ja |

`claude -p` liefert bei 401 selbst Exit 0 mit `is_error: true` (am 24.09. verifiziert);
deshalb ist die JSON-Auswertung Pflicht.

### 5.3 `bin/alert.sh`

Schnittstelle: `alert.sh <ART> <Text…>` sowie `alert.sh unit-failed <unit>` (liest
`last-failure` bzw. Journal-Ende der Unit) und `alert.sh --test`.

Reihenfolge, jede Stufe unabhängig von der vorigen:

1. Journal: `logger -p user.err -t ai-news-alert "[ART] Text"`.
2. Statusdateien: `alerts.log` (Historie), `last-alert` (für `check.sh`; wird vom nächsten erfolgreichen Lauf gelöscht).
3. CallMeBot: `curl -fsS -m 20 -G https://api.callmebot.com/whatsapp.php --data-urlencode phone=… --data-urlencode apikey=… --data-urlencode text=…`. Antwort-HTML wird auf „queued" geprüft; Fehlschlag landet im Journal.
4. Drosselung: pro ART höchstens alle 12 h extern (Stempeldatei), `--force` hebt das auf.

Nachrichtenform: kurz, mit Grund und nächstem Schritt, z. B.
`⚠ ai-news: Briefing-Lauf 3× gescheitert (RUN: model unavailable). Nächster Versuch morgen 07:15. Log: journalctl -u ai-news-dashboard-daily` oder
`⛔ ai-news: Token ungültig (401). Fix: claude setup-token → watchdog.env`.

### 5.4 `bin/watchdog.sh`

Alle 30 min, nur Prüfung und Alarm, keine Reparatur:

| Prüfung | Alarm |
|---|---|
| `TOKEN_CREATED` + 365 d − heute ≤ 14 d | TOKEN, täglich einmal |
| Briefing-Alter ≥ 2 Tage (aus `data-snapshot-date`) | STALE, alle 12 h (fängt „Timer feuert nicht", „Maschine war aus", „Deploy fehlte") |
| `dashboards/youtube/data.json` älter als 30 h | YOUTUBE, alle 12 h |
| `daily.service` im Zustand `failed` und kein Alarm in 12 h | FAILED (Sicherheitsnetz, falls OnFailure nicht griff) |
| Sonntag 09:00–09:30, `HEARTBEAT=1` | „✅ ai-news lebt. Letztes Briefing: <Datum>, letzter Lauf: <Zeit>, Token noch <n> Tage" |

`--dry-run` zeigt alle Werte ohne zu senden; `check.sh` nutzt das.

### 5.5 `~/.config/ai-news-dashboard/watchdog.env` (600, nie im Repo)

```
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-…   # aus `claude setup-token`, 1 Jahr
TOKEN_CREATED=2026-09-24                 # für die Ablaufwarnung
CALLMEBOT_PHONE=49…                      # bereits eingetragen (24.09.)
CALLMEBOT_APIKEY=…                       # bereits eingetragen (24.09.)
CLAUDE_MODEL=claude-opus-4-8             # optional, Default im Skript
MAX_BUDGET_USD=30                        # optional, Default im Skript
HEARTBEAT=1                              # optional, Sonntags-Lebenszeichen
```

Der Token ist bewusst NICHT in `~/.claude/settings.json`: global gesetzt würde er
Remote Control der interaktiven Sessions blockieren (offenes Issue #96076).

### 5.6 `DAILY_UPDATE.md`

Neue Sektion „Betriebsmodus: unbeaufsichtigt" direkt nach der Einleitung:

- Es gibt niemanden, der Rückfragen beantwortet. Keine `AskUserQuestion`, kein Warten.
- Konservativ entscheiden: lieber 3 statt 6 Breaking-News-Items, kein Füllcontent.
- Bei echter Blockade (z. B. `git push` abgelehnt, Quellen komplett tot): letzte
  Ausgabezeile `BLOCKED: <Grund>` und aufhören. Der Wrapper wiederholt später.
- Schritt 8 (Status-Bilanz) ist die letzte Ausgabezeile des Laufs.

Entfernt werden die `/loop`-Bezüge (Zeilen 4 und 270). Schritte 0–7 bleiben inhaltlich unverändert.

### 5.7 `bin/check.sh`

Sektion „background sessions" wird zu „daily run": letzter Lauf (aus `last-run.json`:
Zeit, Exit, Dauer, Kosten, Bilanz), Zustand von `daily.service` und `daily.timer`
(nächster Start), Watchdog-`--dry-run`-Ausgabe, letzter Alarm. Die Sektionen HTTP,
Freshness, YouTube bleiben.

### 5.8 `install.sh`

Vorlagen für die neuen Units, Entfernen der alten (`disable --now` + Datei löschen),
SELinux-Verzeichnisregel, `EnvironmentFile`-Pfad aus `$HOME` des Run-Users. Prüft,
dass `watchdog.env` existiert und `CLAUDE_CODE_OAUTH_TOKEN` gesetzt ist, sonst Abbruch
mit Anleitung. Ein `sudo`-Aufruf für alle Unit-Operationen.

## 6. Sicherheit

- Secrets nur in `watchdog.env` (600) und in der Prozessumgebung der drei Units.
  Kein `echo`, kein `set -x` in Skripten, die die Datei sourcen.
- Der Token gilt nur für die Units. Interaktive Sessions nutzen weiter den Keychain-Login.
- CallMeBot ist ein Drittanbieter: Nachrichten enthalten keine Secrets, keine URLs mit Keys.
  Der Dienst ist „personal use only"; Ausfälle des Dienstes fängt das Sonntags-Lebenszeichen.
- `--dangerously-skip-permissions` bleibt nötig (unbeaufsichtigt). Das Repo enthält den
  Prompt; wer den Prompt ändern kann, steuert den Lauf. Unverändert gegenüber heute.
- Phase 5 (Channel-Plugin): Allowlist ausschließlich auf Marcs Nummer; Plugin ist
  Community-Software mit verknüpftem Gerät, läuft nur in interaktiven Sessions.

## 7. Migration und Rückbau

| Phase | Wer | Schritte | Ergebnis |
|---|---|---|---|
| 0 Vorbereitung | Marc | `claude setup-token` (Browser); Token + `TOKEN_CREATED` in `watchdog.env` | Auth für Oneshot vorhanden |
| 1 Bauen | Claude | `run-daily.sh`, `alert.sh`, `watchdog.sh`, Unit-Vorlagen, `install.sh`, `DAILY_UPDATE.md`, `check.sh`, Tests, Doku | Alles committet, alte Session läuft weiter |
| 2 Installieren | Marc | `sudo ./install.sh` (ein sudo) | Neue Units aktiv, alte entfernt |
| 3 Generalprobe | beide | a) `sudo systemctl start ai-news-dashboard-daily.service` an einem Tag mit fertigem Briefing → Exit 0 idempotent. b) Fehlerinjektion: `alert.sh --test`; dann Lauf mit ungültigem Token via `systemd-run` + Test-Env → WhatsApp „401" kommt an. c) Erster echter Lauf am Folgetag 07:15 beobachten. | Kanal und Retry verifiziert |
| 4 Rückbau | Claude | `claude stop <sid>`, `start-daily-loop.sh`, `loop.sh`, `verify-daily-loop.sh` löschen; CLAUDE.md-Abschnitte zur Session-Mechanik durch Runbook ersetzen, alte Failure-Modes als „Historie"; Memory aktualisieren | Kein Session-Code mehr |
| 5 Optional | Marc + Claude | WhatsApp-Channel-Plugin in interaktiver Session einrichten (Allowlist, Test) | Statusabfragen vom Handy |

Während Phase 1–2 bleibt die heutige Session mit Watchdog aktiv; Phase 4 erst nach
erfolgreichem echtem Lauf (3c).

## 8. Tests

- `tests/test-run-daily.sh`: füttert die JSON-Auswertung mit Fixtures (Erfolg; `is_error`
  + 401; `result` mit `BLOCKED:`; Erfolg ohne frisches Briefing) und prüft Exit-Codes.
  Läuft ohne Netz und ohne Token (Parser als Funktion mit `--parse <datei>` aufrufbar).
- `run-daily.sh --dry-run`, `watchdog.sh --dry-run`: Preflight/Prüfwerte ohne Nebenwirkung.
- `alert.sh --test`: echte Testnachricht.
- `bin/verify-daily.sh`: löst `daily.service` und `watchdog.service` per systemd aus,
  prüft `Result`, `ExecMainStatus`, Journal; ersetzt `verify-daily-loop.sh`.
- Fehlerinjektion (Phase 3b) mit `systemd-run -p EnvironmentFile=<test.env>`.

## 9. Annahmen und Risiken

| Annahme | Absicherung |
|---|---|
| `claude -p` hat im Oneshot dieselben Tools (WebSearch, WebFetch, Bash, Edit) wie die bisherige Session | Generalprobe 3a/3c; Fallback: `--allowedTools` explizit setzen |
| Ablaufdatum des Setup-Tokens ist lokal nicht lesbar | `TOKEN_CREATED` manuell, Warnung nach 351 Tagen |
| CallMeBot kann ausfallen oder pausiert werden („Stop") | Sonntags-Lebenszeichen; Ausbleiben fällt auf |
| Claude-Code-Push im `-p`-Modus ungeprüft | Testpunkt in Phase 3; kein Pflichtkanal |
| `ExecStartPost=deploy.sh` unter `ProtectHome=read-only` ungeprüft | Phase 3; bei Problem `ReadWritePaths` um `~/.ssh/known_hosts` ergänzen |
| Modell `claude-opus-4-8` bleibt verfügbar | per `CLAUDE_MODEL` in `watchdog.env` austauschbar ohne Code |

## 10. Quellen

- CallMeBot WhatsApp-API: <https://www.callmebot.com/blog/free-api-whatsapp-messages/>
- Claude Code WhatsApp-Channel-Plugins (Community): <https://github.com/rich627/whatsapp-claude-plugin>, <https://github.com/diogo85/claude-code-whatsapp>
- `setup-token` und Remote Control schließen sich bei globalem Env aus: <https://github.com/anthropics/claude-code/issues/96076>
- Headless `claude -p` ohne Refresh-Pfad: <https://github.com/anthropics/claude-code/issues/79685>
- Headless-Setup mit `setup-token`: <https://gist.github.com/coenjacobs/d37adc34149d8c30034cd1f20a89cce9>
- Meta WhatsApp Cloud API (verworfen, zu schwer): <https://wexio.io/blog/free-whatsapp-business-api>
