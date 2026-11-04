#!/usr/bin/env bash
# Scheduled yt-dlp self-update for the Aria backend.
#
# YouTube breaks extraction often; yt-dlp ships fixes almost daily. This script
# upgrades yt-dlp inside the backend venv and restarts the service ONLY if the
# version actually changed (so we don't bounce playback for a no-op). A restart
# that fails is retried on the next run. Wire it to aria-yt-dlp-update.timer
# (daily). Logs to stdout -> journald.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="${ARIA_VENV:-$SCRIPT_DIR/.venv}"
SERVICE="${ARIA_SERVICE:-aria-backend}"
PIP="$VENV/bin/pip"
PY="$VENV/bin/python"
# Exists while the installed yt-dlp is newer than the one the service has loaded.
# Without it, a failed restart would never be retried: the next run sees no
# version change, and the service keeps running the old code.
RESTART_PENDING="$VENV/.yt-dlp-restart-pending"

before="$($PY -c 'import yt_dlp; print(yt_dlp.version.__version__)' 2>/dev/null || echo none)"
echo "[update-yt-dlp] current yt-dlp: $before"

"$PIP" install --upgrade --quiet yt-dlp

after="$($PY -c 'import yt_dlp; print(yt_dlp.version.__version__)')"
echo "[update-yt-dlp] after upgrade: $after"

if [ "$before" != "$after" ]; then
    echo "[update-yt-dlp] version changed $before -> $after"
    touch "$RESTART_PENDING"
fi

if [ -e "$RESTART_PENDING" ]; then
    echo "[update-yt-dlp] restarting $SERVICE"
    sudo systemctl restart "$SERVICE"
    rm -f "$RESTART_PENDING"
else
    echo "[update-yt-dlp] no change; not restarting"
fi
