# Weekly Update Workflow · ai-news-dashboard

Dieses Dokument ist die Anweisung für den wöchentlichen Lauf. Er wird von
systemd sonntags um 13:30 als `claude -p`-Oneshot gestartet
(`JOB=weekly bin/run-daily.sh`) und pflegt vier Seiten, die sich langsamer
ändern als das Tagesbriefing:

| Seite | Datei | Inhalt |
|---|---|---|
| Regulatorik | `dashboards/regulation/index.html` | Regulatorik-Tracker DACH/EU: Fristen, Status, Leitlinien |
| Coding-Tools | `dashboards/coding-tools/index.html` | Vergleich der AI-Coding-Tools: Preise, Features, Lizenz, Self-Host |
| Kalender | `dashboards/calendar/index.html` | AI-Events der nächsten 12 Monate |
| Extensions | `dashboards/extensions/index.html` | MCP-Server und Claude-Code-Plugins/Skills |

## Betriebsmodus: unbeaufsichtigt

- Es gibt niemanden, der Rückfragen beantwortet. Stelle keine Fragen und warte
  auf nichts; `AskUserQuestion` ist gesperrt.
- Entscheide konservativ selbst. Ändere nur, was du mit einer Quelle belegen
  kannst (WebSearch/WebFetch). Lieber eine Angabe unverändert lassen als raten.
  Keine erfundenen Zahlen, Termine, Versionen oder Preise.
- Bei einer echten Blockade (z. B. `git push` wird abgelehnt, Websuche liefert
  dauerhaft Fehler): gib als **letzte Ausgabezeile** `BLOCKED: <Grund in einem
  Satz>` aus und höre auf. Der Wrapper wiederholt den Lauf später.
- Deine letzte Ausgabezeile im Erfolgsfall ist die `STATUS:`-Zeile aus Schritt 7.

**Du bist Claude und führst diesen Workflow eigenständig aus.**

---

## 0. Vorbereitung

- Working directory: `/home/szymansk/Projects/agentic_info_dashboard`
- Heutiges Datum frisch ermitteln: `date -I`.
- **Idempotenz**: Lies `data-snapshot-date` im `<body>` aller vier Seiten. Tragen
  alle vier schon `<heute>`, wurde der Lauf heute erledigt → STOP mit
  `STATUS: Seiten bereits aktualisiert (<heute>)`.
- Lies jede Seite vollständig, bevor du sie änderst. Übernimm das vorhandene
  Markup-Muster exakt (Klassen, `data-*`-Attribute, Reihenfolge). Style-Block,
  Script-Tags, Filterleisten, Navigation und Footer bleiben **unverändert**.

## Allgemeine Regeln für alle Seiten

- Sprache deutsch, Stil sachlich, knapp, kein Hype.
- Deutsche Anführungszeichen „…" schließen immer mit `"` (U+201D), niemals mit
  ASCII `"` — sonst brechen Attribute und JS-Strings.
- Personen-Namen mit `<span data-person="<slug>">…</span>` umschließen, wenn der
  Slug in `dashboards/_shared/people.js` existiert.
- Absolute Pfade bleiben `/foo` (niemals `/agentic-info-dashboard/foo`);
  `docs/` wird nie von Hand bearbeitet.
- Jede inhaltliche Änderung braucht mindestens eine Quelle, die du in diesem
  Lauf geöffnet hast. Wo die Seite Quellen-Links vorsieht, setze sie.
- Wenn sich an einer Seite inhaltlich nichts geändert hat: nur ihr Datum
  aktualisieren (Schritt 5). Das Datum bedeutet „geprüft am", nicht „geändert am".

## 1. Regulatorik (`dashboards/regulation/index.html`)

Einträge sind `<article class="item s-…" data-reg="…" data-date="…" data-status="…">`
mit Status `applied` / `now` / `soon` / `future`.

1. Prüfe für jeden Eintrag, ob Datum und Status noch stimmen. Rückt eine Frist
   in die Vergangenheit, Status und CSS-Klasse anpassen (`s-future` → `s-soon`
   → `s-now` → `s-applied`), ebenso das Status-Pill.
2. Suche nach neuen Schritten der letzten Wochen: EU AI Act (Durchführungsakte,
   Leitlinien, Codes of Practice, Verschiebungen), NIS-2-Umsetzung in DE,
   BSI, BaFin (DORA, KI-Aufsicht), DSGVO-Aufsicht zu KI, Data Act, CRA.
   Neue relevante Punkte als Eintrag im selben Muster ergänzen.
3. Einträge, die seit mehr als 12 Monaten „applied" sind und keine laufende
   Relevanz mehr haben, dürfen entfallen. Die Seite soll fokussiert bleiben.

## 2. Coding-Tools (`dashboards/coding-tools/index.html`)

Einträge sind `<article class="tool" data-price="…" data-license="…" data-host="…">`
mit `h2`, `.price-bracket`, `.summary` und `dl.specs`.

1. Prüfe je Tool Preise, Backend-Modelle, Agent-Modus, Lizenz und Self-Host
   gegen die offizielle Produkt- bzw. Preisseite. Abweichungen korrigieren und
   die `data-*`-Filterattribute konsistent halten.
2. Neue Tools nur aufnehmen, wenn sie nennenswerte Enterprise-Verbreitung oder
   einen großen Launch haben. Eingestellte Tools als eingestellt markieren oder
   entfernen.
3. Das Badge im `h1` (`<span class="badge">Stand …</span>`) auf den aktuellen
   Monat setzen, z. B. `Stand Oktober 2026`.

## 3. Kalender (`dashboards/calendar/index.html`)

Monatsblöcke mit `<h2>Monat Jahr</h2>` und `<article class="event" data-type="…"
data-verify="exact|pattern|…">`.

1. Vergangene Monate und Events entfernen; das Fenster sind die kommenden
   12 Monate ab heute. Für neu ins Fenster rückende Monate einen Block anlegen.
2. Events mit `data-verify="pattern"` (geschätzt) prüfen: steht das Datum jetzt
   offiziell fest, Datum eintragen und auf `exact` setzen.
3. Neue große Events aufnehmen (Hersteller-Konferenzen, wichtige Fachkonferenzen,
   regulatorische Stichtage), jeweils mit offizieller Event-Seite als Beleg.

## 4. Extensions (`dashboards/extensions/index.html`)

Einträge sind `<article class="ext" data-uc="…" data-source="…">` in den Sektionen
„MCP-Server" und „Claude Code Plugins & Skills".

1. Prüfe je Eintrag, ob Repository bzw. Seite noch existiert und gepflegt wird.
   Archivierte oder verschwundene Einträge entfernen.
2. Neue verbreitete MCP-Server und Plugins aufnehmen (offizielle Anthropic- und
   Hersteller-Server zuerst), im vorhandenen Muster inklusive `data-uc` und
   `data-source`.

## 5. Datum setzen

Für jede der vier Seiten: `<body data-snapshot-date="<heute>" …>` setzen und,
falls vorhanden, sichtbare „Stand"/„last-updated"-Angaben anpassen.
`data-snapshot-mode="live"` bleibt.

## 6. Verifikation und Deploy

```bash
bin/verify-pages.sh --pre-deploy dashboards/regulation/index.html \
  dashboards/coding-tools/index.html dashboards/calendar/index.html \
  dashboards/extensions/index.html
```

Muss mit `RESULT: ok` enden. Bei `RESULT: quality: …` den genannten Punkt
beheben (z. B. abgeschnittenes HTML) und erneut prüfen. Lässt es sich nicht
beheben: `BLOCKED: <Grund>` und aufhören.

Dann deployen:

```bash
bin/deploy.sh "weekly: seiten $(date -I)"
```

`deploy.sh` baut `docs/`, staged nur `dashboards/` und `docs/`, committet und
pusht. Endet es mit Exit-Code ≠ 0: NICHT erzwingen. Einmal `git fetch origin`,
bei non-fast-forward ohne Konflikte `git rebase origin/main` und `deploy.sh`
erneut. Scheitert es danach weiter: `BLOCKED: Deploy fehlgeschlagen — <erste
Zeile der Fehlermeldung>`.

## 7. Status

Letzte Ausgabezeile, beginnend mit `STATUS:`:

```
STATUS: Wochenlauf vom <heute>: Regulatorik <n> geändert/<m> neu, Coding-Tools
<n> geändert/<m> neu, Kalender <n> entfernt/<m> neu, Extensions <n> entfernt/<m> neu.
Deploy: ✓ (<commit-hash>)
```

`bin/run-daily.sh` schreibt sie nach `~/.local/state/ai-news-dashboard/last-run-weekly.json`.

## Was du NICHT änderst

- `dashboards/ai-news/`, `dashboards/it-services/`, `dashboards/youtube/` — gehören
  zum Tageslauf bzw. YouTube-Fetch
- `dashboards/_shared/people.js`, `dashboards/whoiswho/`, `dashboards/sources/`
- `bin/`, `scripts/`, `tests/`, `*.md`, systemd-Units, `docs/` von Hand
