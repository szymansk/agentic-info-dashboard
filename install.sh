#!/usr/bin/env bash
#
# install.sh — Setup für ai-news-dashboard auf einem frischen Linux-System.
#
# Was passiert:
#   1. Voraussetzungen prüfen (python3, claude, sudo)
#   2. Pfade + User aus aktueller Umgebung ableiten
#   3. systemd-Units rendern (Pfade/User einsetzen) und installieren
#   4. Webserver + YouTube-Timer + Daily-Loop aktivieren
#   5. Firewall (firewalld) öffnen, falls vorhanden
#   6. Initial-Fetch der YouTube-Daten
#   7. Health-Check zum Abschluss
#
# Usage:
#   ./install.sh                 # Default-Port 8000
#   PORT=9000 ./install.sh       # eigener Port
#   SKIP_FIREWALL=1 ./install.sh # ohne firewalld-Eintrag
#   SKIP_DAILY_LOOP=1 ./install.sh # ohne Claude Background-Session
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_USER="${USER:-$(id -un)}"
RUN_GROUP="$(id -gn)"
PORT="${PORT:-8000}"
SKIP_FIREWALL="${SKIP_FIREWALL:-0}"
SKIP_DAILY_LOOP="${SKIP_DAILY_LOOP:-0}"

PY="$(command -v python3 || true)"
CLAUDE="$(command -v claude || true)"

# ─── Output ──────────────────────────────────────────────────────────
red()    { printf "\033[31m%s\033[0m" "$*"; }
green()  { printf "\033[32m%s\033[0m" "$*"; }
yellow() { printf "\033[33m%s\033[0m" "$*"; }
bold()   { printf "\033[1m%s\033[0m" "$*"; }
hdr()    { printf "\n%s\n" "$(bold "── $* ──")"; }

# ─── 1. Voraussetzungen ──────────────────────────────────────────────
hdr "1. Voraussetzungen prüfen"

if [ -z "$PY" ]; then
  red "✗"; echo " python3 nicht gefunden"; exit 1
fi
green "✓"; echo " python3 → $PY ($($PY --version 2>&1))"

if ! command -v systemctl > /dev/null; then
  red "✗"; echo " systemd / systemctl nicht gefunden"; exit 1
fi
green "✓"; echo " systemctl vorhanden"

if ! sudo -n true 2>/dev/null && ! sudo -v 2>/dev/null; then
  yellow "⚠"; echo " sudo wird Passwort verlangen (das ist OK)"
fi

if [ -z "$CLAUDE" ] && [ "$SKIP_DAILY_LOOP" != "1" ]; then
  yellow "⚠"; echo " claude binary nicht gefunden"
  echo "    → Daily-Loop wird übersprungen (setze SKIP_DAILY_LOOP=1 um die Warnung zu unterdrücken)"
  SKIP_DAILY_LOOP=1
fi
[ -n "$CLAUDE" ] && { green "✓"; echo " claude → $CLAUDE ($($CLAUDE --version 2>&1 | head -1))"; }

# ─── 2. Übersicht ────────────────────────────────────────────────────
hdr "2. Setup-Konfiguration"
cat <<EOF
  Projekt-Pfad:    $PROJECT_DIR
  Run as User:     $RUN_USER:$RUN_GROUP
  Webserver-Port:  $PORT
  Firewall öffnen: $([ "$SKIP_FIREWALL" = "1" ] && echo "nein (SKIP_FIREWALL=1)" || echo "ja, wenn firewalld läuft")
  Daily-Loop:      $([ "$SKIP_DAILY_LOOP" = "1" ] && echo "nein (übersprungen)" || echo "ja, via claude --bg")

EOF
read -rp "Weitermachen? [Y/n] " ans
[[ "${ans:-Y}" =~ ^[Yy]?$ ]] || { echo "abgebrochen"; exit 0; }

# ─── 3. systemd Unit-Files rendern + installieren ────────────────────
hdr "3. systemd-Units rendern und installieren"

TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT

# Webserver
cat > "$TMP/ai-news-dashboard.service" <<EOF
[Unit]
Description=AI News Dashboard Server
Documentation=file://$PROJECT_DIR/README.md
After=network.target

[Service]
Type=simple
User=$RUN_USER
Group=$RUN_GROUP
WorkingDirectory=$PROJECT_DIR
ExecStart=$PY $PROJECT_DIR/serve.py $PORT
Restart=on-failure
RestartSec=5

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$PROJECT_DIR
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF

# YouTube fetch (oneshot)
cat > "$TMP/ai-news-dashboard-youtube-fetch.service" <<EOF
[Unit]
Description=Fetch latest AI YouTube videos (RSS) and refresh dashboard data
Documentation=file://$PROJECT_DIR/scripts/fetch-youtube.py
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=$RUN_USER
Group=$RUN_GROUP
WorkingDirectory=$PROJECT_DIR
ExecStart=$PY $PROJECT_DIR/scripts/fetch-youtube.py

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$PROJECT_DIR/dashboards/youtube
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
EOF

# YouTube fetch timer
cat > "$TMP/ai-news-dashboard-youtube-fetch.timer" <<EOF
[Unit]
Description=Daily YouTube refresh for AI News Dashboard

[Timer]
OnCalendar=*-*-* 06:00:00
Persistent=true
RandomizedDelaySec=300
Unit=ai-news-dashboard-youtube-fetch.service

[Install]
WantedBy=timers.target
EOF

# Daily loop (Claude background session orchestrator)
if [ "$SKIP_DAILY_LOOP" != "1" ]; then
cat > "$TMP/ai-news-dashboard-daily-loop.service" <<EOF
[Unit]
Description=Ensure Claude background session 'daily-ai-update' is running
Documentation=file://$PROJECT_DIR/DAILY_UPDATE.md
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=$RUN_USER
Group=$RUN_GROUP
WorkingDirectory=$PROJECT_DIR
ExecStart=$PROJECT_DIR/bin/start-daily-loop.sh
KillMode=none

[Install]
WantedBy=multi-user.target
EOF
fi

echo "  Installiere Units nach /etc/systemd/system/ (sudo)"
sudo install -m 644 "$TMP"/*.service "$TMP"/*.timer /etc/systemd/system/
sudo systemctl daemon-reload
green "✓"; echo " Units installiert + systemd reloaded"

# ─── 4. Services aktivieren ──────────────────────────────────────────
hdr "4. Services aktivieren + starten"

sudo systemctl enable --now ai-news-dashboard.service
green "✓"; echo " ai-news-dashboard.service aktiv"

sudo systemctl enable --now ai-news-dashboard-youtube-fetch.timer
green "✓"; echo " ai-news-dashboard-youtube-fetch.timer aktiv"

if [ "$SKIP_DAILY_LOOP" != "1" ]; then
  sudo systemctl enable ai-news-dashboard-daily-loop.service
  # Starten überspringen, weil claude --dangerously-skip-permissions
  # vermutlich erst interaktiv akzeptiert sein muss
  yellow "ℹ"; echo " daily-loop ist enabled (startet beim nächsten Boot)"
  yellow "  "; echo " Für sofort: ./bin/start-daily-loop.sh   (interaktiv testen)"
fi

# ─── 5. Firewall ─────────────────────────────────────────────────────
if [ "$SKIP_FIREWALL" != "1" ]; then
  hdr "5. Firewall (firewalld)"
  if systemctl is-active --quiet firewalld; then
    ZONE="$(firewall-cmd --get-default-zone 2>/dev/null || echo public)"
    sudo firewall-cmd --zone="$ZONE" --add-port="$PORT/tcp" --permanent
    sudo firewall-cmd --reload
    green "✓"; echo " Port $PORT/tcp in Zone $ZONE freigegeben"
  else
    yellow "ℹ"; echo " firewalld inaktiv — überspringe (ufw/nftables ggf. manuell)"
  fi
fi

# ─── 6. Initial YouTube-Fetch ────────────────────────────────────────
hdr "6. Initial YouTube-Fetch"
sudo systemctl start ai-news-dashboard-youtube-fetch.service
sleep 1
if [ -f "$PROJECT_DIR/dashboards/youtube/data.json" ]; then
  green "✓"; echo " data.json geschrieben ($(stat -c %s "$PROJECT_DIR/dashboards/youtube/data.json") bytes)"
else
  yellow "⚠"; echo " data.json fehlt nach Fetch — siehe: journalctl -u ai-news-dashboard-youtube-fetch.service"
fi

# ─── 7. Health-Check ─────────────────────────────────────────────────
hdr "7. Health-Check"
"$PROJECT_DIR/bin/check.sh" || true

# ─── Fertig ──────────────────────────────────────────────────────────
hdr "✓ Setup fertig"
IP="$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
cat <<EOF

  Lokal:    http://localhost:$PORT/
  Im LAN:   http://${IP:-<ip>}:$PORT/

  Nützlich:
    systemctl status ai-news-dashboard
    systemctl list-timers ai-news-dashboard-*
    journalctl -u ai-news-dashboard-youtube-fetch -n 20
    ./bin/check.sh
$([ "$SKIP_DAILY_LOOP" != "1" ] && echo "    ./bin/start-daily-loop.sh   # daily-loop sofort starten")
EOF
