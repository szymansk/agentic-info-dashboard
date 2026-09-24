#!/usr/bin/env bash
#
# install.sh — Setup für ai-news-dashboard auf einem frischen Linux-System.
#
# Was passiert:
#   1. Voraussetzungen prüfen (python3, claude, sudo)
#   2. Pfade + User aus aktueller Umgebung ableiten
#   3. systemd-Units rendern (Pfade/User einsetzen) und installieren
#   4. Webserver + YouTube-Timer + Daily-Oneshot + Watchdog aktivieren
#   5. Firewall (firewalld) öffnen, falls vorhanden
#   6. Initial-Fetch der YouTube-Daten
#   7. Health-Check zum Abschluss
#
# Usage:
#   ./install.sh                 # Default-Port 8000
#   PORT=9000 ./install.sh       # eigener Port
#   SKIP_FIREWALL=1 ./install.sh # ohne firewalld-Eintrag
#   SKIP_DAILY=1 ./install.sh      # ohne Daily-Oneshot/Watchdog
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_USER="${USER:-$(id -un)}"
RUN_GROUP="$(id -gn)"
PORT="${PORT:-8000}"
SKIP_FIREWALL="${SKIP_FIREWALL:-0}"
SKIP_DAILY="${SKIP_DAILY:-0}"

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

if [ -z "$CLAUDE" ] && [ "$SKIP_DAILY" != "1" ]; then
  yellow "⚠"; echo " claude binary nicht gefunden"
  echo "    → Daily-Oneshot wird übersprungen (setze SKIP_DAILY=1 um die Warnung zu unterdrücken)"
  SKIP_DAILY=1
fi
[ -n "$CLAUDE" ] && { green "✓"; echo " claude → $CLAUDE ($($CLAUDE --version 2>&1 | head -1))"; }

# Env-Dateien (Secrets) müssen VOR der Installation existieren und gültig sein
CONF_DIR="$HOME/.config/ai-news-dashboard"
if [ "$SKIP_DAILY" != "1" ]; then
  # shellcheck source=bin/lib-daily.sh
  . "$PROJECT_DIR/bin/lib-daily.sh"
  for f in daily.env alert.env; do
    if ! env_file_valid "$CONF_DIR/$f"; then
      red "✗"; echo " $CONF_DIR/$f fehlt oder ist ungültig (KEY=wert, Kommentare nur als ganze Zeilen)"
      echo "    daily.env: claude setup-token → bin/set-token.sh · alert.env: CALLMEBOT_PHONE/CALLMEBOT_APIKEY"
      exit 1
    fi
  done
  grep -q '^CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-' "$CONF_DIR/daily.env" || { red "✗"; echo " kein Setup-Token in daily.env — bin/set-token.sh"; exit 1; }
  green "✓"; echo " daily.env + alert.env vorhanden und gültig"
fi

# ─── 2. Übersicht ────────────────────────────────────────────────────
hdr "2. Setup-Konfiguration"
cat <<EOF
  Projekt-Pfad:    $PROJECT_DIR
  Run as User:     $RUN_USER:$RUN_GROUP
  Webserver-Port:  $PORT
  Firewall öffnen: $([ "$SKIP_FIREWALL" = "1" ] && echo "nein (SKIP_FIREWALL=1)" || echo "ja, wenn firewalld läuft")
  Daily-Oneshot:   $([ "$SKIP_DAILY" = "1" ] && echo "nein (übersprungen)" || echo "ja, Timer 07:15 → claude -p")

EOF
read -rp "Weitermachen? [Y/n] " ans
[[ "${ans:-Y}" =~ ^[Yy]?$ ]] || { echo "abgebrochen"; exit 0; }
sudo -v   # ein Passwort-Prompt jetzt, Timestamp für alle folgenden sudo-Aufrufe

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
ExecStartPost=/usr/bin/bash $PROJECT_DIR/bin/deploy.sh
TimeoutStartSec=10min
Environment=GIT_TERMINAL_PROMPT=0 GH_NO_UPDATE_NOTIFIER=1

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$PROJECT_DIR
ReadWritePaths=-$HOME/.config/gh
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

# Daily-Oneshot (claude -p) + Alert-Template + Watchdog
if [ "$SKIP_DAILY" != "1" ]; then
cat > "$TMP/ai-news-dashboard-daily.service" <<EOF
[Unit]
Description=Daily AI news briefing (claude -p oneshot)
Documentation=file://$PROJECT_DIR/specs/2026-09-24-daily-run-oneshot-design.md
After=network-online.target ai-news-dashboard-youtube-fetch.service
Wants=network-online.target
OnFailure=ai-news-dashboard-alert@%p.service
StartLimitIntervalSec=12h
StartLimitBurst=3

[Service]
Type=oneshot
User=$RUN_USER
Group=$RUN_GROUP
WorkingDirectory=$PROJECT_DIR
Environment=DISABLE_AUTOUPDATER=1 GIT_TERMINAL_PROMPT=0 GH_NO_UPDATE_NOTIFIER=1
StandardInput=null
ExecStart=/usr/bin/bash $PROJECT_DIR/bin/run-daily.sh
TimeoutStartSec=90min
TimeoutStopSec=3min
Restart=on-failure
RestartSec=2h
RestartPreventExitStatus=3 4 8 9 10 11
InaccessiblePaths=-$HOME/.ssh
EOF

cat > "$TMP/ai-news-dashboard-daily.timer" <<EOF
[Unit]
Description=Daily AI news briefing at 07:15

[Timer]
OnCalendar=*-*-* 07:15:00
Persistent=true
Unit=ai-news-dashboard-daily.service

[Install]
WantedBy=timers.target
EOF

cat > "$TMP/ai-news-dashboard-alert@.service" <<EOF
[Unit]
Description=Alert for failed unit %i (CallMeBot/ntfy/journal)

[Service]
Type=oneshot
User=$RUN_USER
Group=$RUN_GROUP
WorkingDirectory=$PROJECT_DIR
StandardInput=null
TimeoutStartSec=2min
ExecStart=/usr/bin/bash $PROJECT_DIR/bin/alert.sh unit-failed %i
EOF

cat > "$TMP/ai-news-dashboard-watchdog.service" <<EOF
[Unit]
Description=Watchdog: briefing freshness, token, pages, youtube (alerts only)
OnFailure=ai-news-dashboard-alert@%p.service

[Service]
Type=oneshot
User=$RUN_USER
Group=$RUN_GROUP
WorkingDirectory=$PROJECT_DIR
Environment=DISABLE_AUTOUPDATER=1 GH_NO_UPDATE_NOTIFIER=1
StandardInput=null
TimeoutStartSec=5min
ExecStart=/usr/bin/bash $PROJECT_DIR/bin/watchdog.sh
EOF

cat > "$TMP/ai-news-dashboard-watchdog.timer" <<EOF
[Unit]
Description=Watchdog every 30 minutes

[Timer]
OnCalendar=*-*-* *:00/30:00
Unit=ai-news-dashboard-watchdog.service

[Install]
WantedBy=timers.target
EOF
fi

echo "  Alte Session-Units entfernen (unabhängig von SKIP_DAILY — gehören zum abgelösten Mechanismus)"
for u in ai-news-dashboard-daily-loop.service ai-news-dashboard-healthcheck.timer ai-news-dashboard-healthcheck.service; do
  sudo systemctl disable --now "$u" 2>/dev/null || true
  sudo systemctl reset-failed "$u" 2>/dev/null || true
  sudo rm -f "/etc/systemd/system/$u"
done
if [ "$SKIP_DAILY" != "1" ]; then
  echo "  SELinux: bin/ als bin_t (Defense-in-Depth)"
  if command -v semanage >/dev/null 2>&1; then
    sudo semanage fcontext -a -t bin_t "$PROJECT_DIR/bin(/.*)?" 2>/dev/null \
      || sudo semanage fcontext -m -t bin_t "$PROJECT_DIR/bin(/.*)?"
    sudo restorecon -R "$PROJECT_DIR/bin"
  fi
fi
echo "  Units prüfen (systemd-analyze verify)"
VERIFY_OUT="$(systemd-analyze verify "$TMP"/*.service "$TMP"/*.timer 2>&1 | grep -v "KillMode=none" || true)"
if [ -n "$VERIFY_OUT" ]; then
  red "✗"; echo " systemd-analyze verify meldet Fehler — Installation abgebrochen:"
  echo "$VERIFY_OUT"
  exit 1
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

if [ "$SKIP_DAILY" != "1" ]; then
  sudo systemctl enable --now ai-news-dashboard-daily.timer
  green "✓"; echo " daily.timer aktiv (07:15, Persistent)"
  sudo systemctl enable --now ai-news-dashboard-watchdog.timer
  green "✓"; echo " watchdog.timer aktiv (alle 30 Min)"
  systemctl list-timers ai-news-dashboard-* --no-pager | sed 's/^/    /'
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
$([ "$SKIP_DAILY" != "1" ] && echo "    ./bin/verify-daily.sh        # Oneshot + Watchdog einmal per systemd auslösen")
$([ "$SKIP_DAILY" != "1" ] && echo "    Vor dem ersten 07:15-Lauf: alte Background-Session stoppen —")
$([ "$SKIP_DAILY" != "1" ] && echo "      ./bin/loop.sh attach → /cron list → Eintrag löschen → ./bin/loop.sh stop")
EOF
