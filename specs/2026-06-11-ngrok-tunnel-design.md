# Design: Privater Dashboard-Zugang via ngrok mit GitHub-OAuth

**Datum:** 2026-06-11
**Status:** Entwurf zur Review

## Ziel

Die Dashboards (live ausgeliefert von `serve.py` auf Port 8000) zusätzlich zum
öffentlichen GitHub-Pages-Deployment über einen **privaten, zugangsgeschützten
Kanal** erreichbar machen. Zugriff nur für explizit freigeschaltete Personen,
Anmeldung über GitHub-Konto. GitHub Pages bleibt unverändert der öffentliche
Kanal.

## Entscheidungen (mit Marc abgestimmt)

| Frage | Entscheidung |
|---|---|
| Zweck | Privater Zugang mit Auth zum lokalen Live-Stand |
| Auth | GitHub-OAuth am ngrok-Edge, E-Mail-Allowlist |
| Allowlist | `marc.szymanski@mac.com` (verifizierte E-Mail des GitHub-Kontos) |
| Betrieb | Dauerhaft via systemd, startet beim Boot |
| Domain | `szymansk-dashboards.ngrok.app` (reserviert, ngrok-branded) |
| Mehrere Dashboards | Alles hinter `serve.py` ist automatisch dabei (Landing-Page + `/<slug>/`) |
| Weitere Dienste später | Vorbereitet, aber kein Proxy jetzt (Variante A, siehe Erweiterungspfad) |

## Rahmenbedingungen

- **ngrok-Account**: Hobbyist-Plan — 3 Online-Endpoints, ngrok-branded Domains.
  Belegt: 1 Endpoint durch den gbrain-MCP-Tunnel (`da3dalus.ngrok.app`,
  Port 3131, gestartet von `~/.gbrain/mcp-tunnel-run.sh`). Der Dashboard-Tunnel
  ist Endpoint Nr. 2; ein Slot bleibt frei.
- **Kein Einfluss auf den MCP-Tunnel**: eigener ngrok-Prozess, eigener Port,
  eigene Domain, Auth pro Endpoint. Parallele Agent-Sessions sind auf dem
  Account empirisch verifiziert (2026-06-11).
- **Authtoken** liegt bereits in `~/.config/ngrok/ngrok.yml`.

## Architektur

```
Browser ──HTTPS──▶ ngrok Edge (GitHub-OAuth-Gate, Allowlist)
                       │
                       ▼
            ngrok-Agent (systemd: ai-news-dashboard-tunnel.service)
                       │
                       ▼
            serve.py :8000 (systemd: ai-news-dashboard.service)
                       │
                       ▼
            dashboards/ (Landing-Page + alle <slug>/)
```

### Neue systemd-Unit: `ai-news-dashboard-tunnel.service`

- `Type=simple`, `Restart=always`, `RestartSec=5`
- `After=network-online.target ai-news-dashboard.service`,
  `Requires=ai-news-dashboard.service` — Tunnel läuft nie ohne den Server
- `User=szymansk` (Authtoken-Config liegt im Home)
- ExecStart:

```
ngrok http 8000 \
  --url szymansk-dashboards.ngrok.app \
  --oauth github \
  --oauth-allow-email marc.szymanski@mac.com \
  --log stdout --log-format logfmt
```

- Logs landen im journal: `journalctl -u ai-news-dashboard-tunnel`

### Auth-Verhalten

ngrok erzwingt am Edge — Anfragen erreichen `serve.py` erst **nach** dem Gate:

1. Aufruf der Tunnel-URL → Redirect auf GitHub-Login
2. Login mit beliebigem GitHub-Konto (inkl. 2FA, falls aktiv)
3. ngrok prüft die von GitHub bestätigte E-Mail gegen die Allowlist
4. Nur gelistete E-Mails kommen durch; danach Session-Cookie, kein
   Login pro Seitenaufruf

Weitere Personen freischalten = ein zusätzliches `--oauth-allow-email`-Flag
in der Unit + `daemon-reload` + `restart`. `serve.py` bleibt unverändert und
weiß nichts vom Tunnel.

## Integration ins Projekt

- **`install.sh`**: Installation der neuen Unit ergänzen — eigener
  `sudo`-Aufruf pro Unit (Projektregel: nie mehrere Units in einem Call)
- **`bin/check.sh`**: zwei neue Checks:
  1. Unit `ai-news-dashboard-tunnel.service` aktiv?
  2. Unauthentifizierter `curl -sI https://szymansk-dashboards.ngrok.app/`
     liefert Redirect Richtung GitHub-OAuth (`3xx` + `Location` auf
     `github.com`). Ein `200` ohne Redirect = **roter Alarm**: Tunnel offen
     ohne Auth-Gate.
- **`CLAUDE.md`**: Unit-Tabelle und Architektur-Überblick um den Tunnel
  ergänzen

## Fehlerfälle

| Fall | Verhalten |
|---|---|
| ngrok-Prozess stirbt | systemd `Restart=always` startet neu |
| Reboot | Unit startet automatisch (`WantedBy=multi-user.target`) |
| serve.py down | `Requires=` stoppt den Tunnel mit; kommt mit dem Server zurück |
| Domain nicht claimbar | Fehlermeldung im Journal; Fallback: kostenlose statische Domain (`*.ngrok-free.dev`) — reiner Konfigurationswert, kein Code-Unterschied |
| Account-Limit (3 Endpoints) | Dashboard-Tunnel ist Nr. 2 — kein Konflikt; bei Nr. 4+ greift der Erweiterungspfad |

## Erweiterungspfad: weitere Dienste unter derselben Domain

Heute zeigt der Tunnel direkt auf Port 8000. Wenn später weitere lokale
Dienste unter derselben URL hängen sollen:

1. Reverse Proxy (Caddy) auf z. B. Port 8080 einschieben:
   `/` → serve.py:8000, `/<dienst>/` → Port des Dienstes
2. In der Tunnel-Unit **eine Zahl** ändern (8000 → 8080) — URL, OAuth und
   alles andere bleibt identisch

**Konvention dafür (jetzt schon gültig):** Das bestehende Dashboard-Setup
bleibt auf `/` (seine HTMLs nutzen absolute Pfade — das bekannte
Sub-Path-Problem, vgl. `build-pages.py`). Alle **neuen, externen Dienste**
werden von Anfang an sub-path-fähig gebaut (relative Pfade oder
konfigurierbarer Base-Path), damit sie hinter `/<dienst>/` funktionieren.

Alternativ bleibt der dritte Endpoint-Slot frei für **einen** Dienst mit
eigener Domain und eigenem OAuth-Gate — kombinierbar mit dem Proxy-Weg.

## Nicht im Scope (YAGNI)

- Keine Traffic-Policies, kein Reverse Proxy jetzt
- Keine Änderung an `serve.py`, GitHub Pages, Deploy-Zyklus oder MCP-Tunnel
- Keine pfadweise unterschiedlichen Auth-Regeln (ein Gate für alles)

## Verifikation nach Umsetzung

1. `systemctl status ai-news-dashboard-tunnel` → active (running)
2. `curl -sI https://szymansk-dashboards.ngrok.app/` → `3xx` mit
   `Location: https://github.com/login/oauth/...`
3. `./bin/check.sh` → alle Checks grün, inkl. der zwei neuen
4. Manuell (Marc): URL im Browser öffnen → GitHub-Login → Landing-Page mit
   allen Dashboards sichtbar; Gegentest mit nicht gelistetem Konto → abgewiesen
5. MCP-Tunnel-Regression: `https://da3dalus.ngrok.app` antwortet weiterhin
