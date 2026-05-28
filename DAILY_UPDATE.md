# Daily Update Workflow · ai-news-dashboard

Dieses Dokument ist die Orchestrator-Anweisung für die Background-Session
`daily-ai-update`. Sie wird einmal täglich via `/loop 24h` ausgeführt und
durchläuft die Schritte unten.

**Du bist Claude und führst diesen Workflow eigenständig aus.**

---

## 0. Vorbereitung

- Working directory: `/home/szymansk/Projects/agentic_info_dashboard`
- Heutiges Datum: ermittle es jetzt frisch mit `date -I` (Format: `YYYY-MM-DD`)
- Wochentag (DE) für die Header-Anzeige: `date +%A`
- **Idempotenz**: Prüfe `dashboards/ai-news/archive/<heute>.html`. Existiert
  die Datei bereits, wurde der Workflow heute schon ausgeführt — dann
  STOP und logge „Heute bereits aktualisiert" als Ergebnis.

---

## 1. Datenquellen frisch holen

Führe **parallel** aus (eine Bash-Message mit mehreren Tool-Calls):

1. **Claude Code Releases** (letzte 6) aus der GitHub API:
   ```
   curl -s "https://api.github.com/repos/anthropics/claude-code/releases?per_page=6"
   ```
   Extrahiere pro Release: `tag_name`, `published_at`, `body` (erste ~6 bullets).

2. **AI/Agentic-News der letzten 24h** via WebSearch (mehrere Queries
   parallel für unterschiedliche Blickwinkel):
   - „latest AI agentic news this week" → für die übergreifenden Themen
   - „OpenAI Anthropic DeepMind announcement <heute>" → Lab-Releases
   - „AI startup funding acquisition <letzte 7 Tage>" → M&A
   - „heise KI Agentic AI" → DACH-Bezug

3. **YouTube-Daten aktualisieren**: führe
   `python3 scripts/fetch-youtube.py` aus. Das schreibt
   `dashboards/youtube/data.json` neu.

---

## 2. Breaking News kuratieren & scoren

Aus den News-Treffern wählst du 4–8 Items aus, die du als „Breaking News"
für heute markierst. Für jedes Item bewertest du selbst (LLM-Score 1–10):

- **9–10**: Major model/product release, regulatorischer Schlag, akquirierter
  Lab-Wechsel
- **7–8**: Wichtige Personalie, signifikante Forschungsergebnisse, große
  Subscription-/Pricing-Änderungen
- **5–6**: M&A im Mittelfeld, Marktdaten, Tooling-Releases
- **1–4**: Hintergrund-Storys, Spekulation — meist NICHT aufnehmen

Pro Item brauchst du: `pill-kategorie` (Major Release / Personalie /
Security / Tooling / M&A / Marktdaten / Forschung), `score`, `titel`,
`kurze prägnante zusammenfassung` (2–3 Sätze), `datum`, `quelle/firma`,
optional `link`.

---

## 3. Tagesbriefing schreiben

Du schreibst einen redaktionellen Text auf Niveau eines guten Tech-Journalisten
— **5–15 Min Lesezeit, ~1500–2500 Wörter** —, der:

- mit einer **Lede** beginnt (1 Absatz, ~120 Wörter), der den Tag rahmt
- **3–5 nummerierte Sections** hat (jeweils 200–400 Wörter)
- pro Section eine `<blockquote class="takeaway">` mit „Was es bedeutet"
  enthält
- mit einer **Schlussbemerkung** „Was morgen zu beobachten ist" endet
- Personen-Namen aus `dashboards/_shared/people.js` (PEOPLE-Array) mit
  `<span data-person="<slug>">...</span>` umschließt, damit die Tooltips
  greifen. **Wichtig**: nur Personen-Namen, die im PEOPLE-Array existieren.
  Wenn jemand erwähnt wird, der nicht im Array ist (z. B. ein neuer Player),
  schlage am Ende des Workflows vor, ihn ins Array aufzunehmen.

**Ton**: analytisch, opinionated wo angebracht, kein Hype, keine Floskeln,
deutsch. Style-Vorbild: Stratechery + Bloomberg Tech. Drop Cap auf dem Lede
ist via CSS schon eingerichtet.

---

## 4. Gestrigen Snapshot ins Archiv kopieren

1. Lies `dashboards/ai-news/archive/manifest.json`
2. Finde den Eintrag, dessen `url` aktuell `/ai-news/` ist — das ist „gestern"
3. Kopiere `dashboards/ai-news/index.html` (das ist noch der gestrige Stand!)
   nach `dashboards/ai-news/archive/<gestern>.html`
4. Setze in der Kopie `data-snapshot-mode="live"` → `data-snapshot-mode="archive"`
   (präzises sed: nur das body-Tag treffen, nicht andere Vorkommen)
5. Update manifest.json:
   - Ändere den alten Eintrag (gestern): `url` → `/ai-news/archive/<gestern>.html`
   - Füge neuen Eintrag (heute) hinzu: `url` → `/ai-news/`, mit
     `headline` und `summary` aus dem heutigen Briefing
6. Manifest mit aufsteigender (oder absteigender — sortiert wird in JS)
   Datums-Ordnung speichern

---

## 5. Neues index.html schreiben

Modifiziere `dashboards/ai-news/index.html` so:

- `<body data-snapshot-date="<heute>" data-snapshot-mode="live">` — Datum
  aktualisieren
- **Tagesbriefing**: kompletten Text aus Schritt 3 in die `.briefing-wrap`
  einsetzen (Lede + Sections + Schluss)
- **Breaking News**: Cards aus Schritt 2 in die Breaking-News-Grid einsetzen
  (3-spaltig). Format wie im bestehenden HTML, nur Inhalte ersetzen.
- **Claude Code Releases**: die 6 neuesten aus Schritt 1 in die Release-Liste
  einsetzen. Format: `<div class="release"><div class="ver">vX.Y.Z</div>...`

Wichtig: das umliegende HTML-Gerüst (Nav, Timeline-Bar, Header-Datum-Skript,
Footer, Style-Block, Script-Tags) bleibt **unverändert**.

---

## 5.5. IT-Services-Radar aktualisieren

Das Dashboard `dashboards/it-services/index.html` zeigt einen rollierenden
6-Monats-Radar zu Bedrohungen / Watchlist / Chancen für deutsche
IT-Dienstleister (Fokus adesso). Es wird NICHT jeden Tag komplett neu
geschrieben — du pflegst es **inkrementell**:

1. Schau dir die heutigen Breaking-News aus Schritt 2 an. Markiere jede
   Meldung, die für IT-Service-Dienstleister relevant ist (Beispiele:
   neuer Lab-Berater-Wettbewerb, Tagessatz-Studien, Layoffs bei
   Capgemini/Accenture/IBM/Cognizant, neue AI-Coding-Tools mit Enterprise-
   Adoption, regulatorische Schritte EU/BSI/BaFin, adesso-spezifische News).

2. Pro relevanter Meldung: eine `<article class="event" ...>`-Karte
   im passenden `.col-threat` / `.col-watch` / `.col-chance` einsetzen.
   Karten sortiert nach `data-crit` absteigend innerhalb der Spalte.

3. Felder pro Card: `data-cat` (AI-Tools / Wettbewerb / Regulatorik /
   Talent / Kunden / Markt), `data-date` (ISO), `data-crit` (1–10).
   Krit-Bar-`<span>` Breite = `data-crit * 10%`. Im `.ev-take` einen
   knappen 2-Satz-Take „Für adesso" formulieren.

4. Wenn die Spalte mehr als 6 Events hat: das älteste Event mit niedrigster
   Kritikalität entfernen — das Dashboard soll fokussiert bleiben.

5. Wenn signifikante Verschiebung in der Branche (z. B. drei Bedrohungen ≥ 9
   neu, oder Marktwachstum massiv revidiert): das Klima-Element oben
   (`.klima .status`) anpassen — Icon, Status-Wort, Trend-Text.

6. `<body data-snapshot-date="<heute>">` aktualisieren und unten
   `#last-updated` Text setzen.

Wenn KEINE relevanten IT-Services-News heute: dieses Dashboard NICHT
anfassen, nur `data-snapshot-date` aktualisieren. Karten-Inhalte sind
Wahrheits-Datum, nicht Schreib-Datum.

---

## 6. Verifikation

Nach allen Änderungen:

```bash
# 1. HTML syntaktisch valide?
python3 -c "from html.parser import HTMLParser; HTMLParser().feed(open('dashboards/ai-news/index.html').read()); print('HTML OK')"

# 2. JSON valide?
python3 -m json.tool dashboards/ai-news/archive/manifest.json > /dev/null && echo 'manifest OK'

# 3. Server live-test
curl -s -o /dev/null -w "HTTP %{http_code} · %{size_download}b\n" http://localhost:8000/ai-news/
curl -s -o /dev/null -w "HTTP %{http_code} · %{size_download}b\n" http://localhost:8000/ai-news/archive/<gestern>.html
```

Wenn irgendwas fehlschlägt: STOP, halte an, warte auf User-Input
(die Background-Session zeigt das als „needs input").

---

## 7. Deploy auf GitHub Pages

Nach erfolgreicher Verifikation pushst du den aktuellen Stand live:

```bash
./bin/deploy.sh "daily: briefing <heute>"
```

Das Skript:
1. baut `docs/` neu via `scripts/build-pages.py` (kopiert dashboards/ und
   schreibt absolute Pfade auf `/agentic-info-dashboard/...` um)
2. staged alle Änderungen
3. commitet nur falls etwas neu ist
4. pusht nach `origin/main` — Pages rendert in ~30s neu

Wenn `deploy.sh` mit Exit-Code ≠ 0 endet: STOP, halte an, logge die
Fehlermeldung. NICHT erzwingen.

---

## 8. Status loggen

Am Ende des erfolgreichen Laufs, eine knappe Bilanz ausgeben:

```
Lauf vom <heute>: <N> Breaking-News-Items, <M> Wörter Briefing, gestern
archiviert als <gestern>.html. YouTube refresh: <K> Videos. Claude Code:
v<latest> aktuell. Deploy: ✓
```

Diese Zeile wird im `claude logs daily-ai-update` sichtbar — die ist der
einzige „Heartbeat", den der User von außen sieht.

---

## Was du NICHT änderst

- `dashboards/sources/` — manuell gepflegt
- `dashboards/whoiswho/` — manuell gepflegt
- `dashboards/_shared/people.js` — manuell gepflegt (außer du machst einen
  „Personen-Vorschlag" am Ende, siehe Section 3)
- `serve.py`, `scripts/`, `bin/`, systemd-Units — nur in expliziten
  separaten Sessions ändern

## Wenn etwas schiefgeht

- API rate limit (GitHub) → einmal warten, nochmal probieren, dann
  pausieren und User informieren
- WebSearch liefert dünne Treffer → ggf. weniger Breaking News (3 statt 6)
  ist OK, kein erzwungener Füll-Content
- Snapshot-Konflikt (Archiv-Datei für heute existiert schon) → Idempotenz
  greift schon in Schritt 0, normalerweise unmöglich

## Wenn du fertig bist

`/loop` schläft automatisch für 24h. Du machst nichts weiter.
