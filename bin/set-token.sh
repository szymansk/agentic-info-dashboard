#!/usr/bin/env bash
#
# set-token.sh — schreibt den langlebigen Token aus `claude setup-token` nach
# ~/.config/ai-news-dashboard/daily.env (Spec 5.6). Token kommt über stdin:
#   claude setup-token            # im Browser bestätigen, Token wird angezeigt
#   bin/set-token.sh              # Token einfügen, Enter, Ctrl-D
# Nie als Argument (landet sonst in Shell-History und ps).
# Exit: 0 ok · 2 Token-Format falsch · 3 Datei danach ungültig
#
set -uo pipefail
LOG_TAG=set-token
# shellcheck source=bin/lib-daily.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-daily.sh"

token="$(head -1 | tr -d '[:space:]')"
if ! [[ "$token" =~ ^sk-ant-oat01-[A-Za-z0-9_-]{3,}$ ]]; then
  warn "kein gültiger Setup-Token (erwartet sk-ant-oat01-…)"; exit 2
fi
mkdir -p "$(dirname "$DAILY_ENV")"; chmod 700 "$(dirname "$DAILY_ENV")" 2>/dev/null || true
if [ ! -f "$DAILY_ENV" ]; then
  printf 'CLAUDE_MODEL=claude-opus-4-8\nFALLBACK_MODEL=\nMAX_BUDGET_USD=30\n' > "$DAILY_ENV"
fi
tmp="$(mktemp "${DAILY_ENV}.XXXX")"
grep -vE '^(CLAUDE_CODE_OAUTH_TOKEN|TOKEN_CREATED)=' "$DAILY_ENV" > "$tmp"
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\nTOKEN_CREATED=%s\n' "$token" "$(today)" >> "$tmp"
mv "$tmp" "$DAILY_ENV"; chmod 600 "$DAILY_ENV"
if ! env_file_valid "$DAILY_ENV"; then warn "$DAILY_ENV ist nach dem Schreiben ungültig — Datei prüfen"; exit 3; fi
log "Token gespeichert in $DAILY_ENV (TOKEN_CREATED=$(today), Rechte 600)"
