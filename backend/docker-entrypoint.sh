#!/bin/sh
# Starts the backend and keeps yt-dlp current, because YouTube breaks extraction
# often. A new version takes effect by exiting: Docker's restart policy starts a
# fresh container process, and the tunnel stays up (see compose.yaml).
set -u

# app.py runs with no authentication when the key is empty. This image is meant
# to face the internet, so it refuses to start that way.
key="${ARIA_API_KEY:-}"
if [ "${#key}" -lt 16 ]; then
    echo "[aria] ARIA_API_KEY must be at least 16 characters. Run ./setup.sh or set it in .env." >&2
    exit 1
fi
unset key

INTERVAL="${YTDLP_UPDATE_INTERVAL_SECONDS:-86400}"

ytdlp_version() {
    python -c "from importlib.metadata import version; print(version('yt-dlp'))"
}

update_ytdlp() {
    # A failed update must never stop the server, for example when offline.
    pip install --quiet --disable-pip-version-check --timeout 15 --retries 1 \
        --upgrade 'yt-dlp[default]' \
        || echo "[aria] yt-dlp update failed; keeping $(ytdlp_version)" >&2
}

update_ytdlp
echo "[aria] starting with yt-dlp $(ytdlp_version)"

# --no-access-log: uvicorn's access line would write library search text to the
# logs. The app's own middleware logs request paths only.
python -m uvicorn --app-dir /app app:app --host 0.0.0.0 --port 8000 \
    --no-access-log --timeout-graceful-shutdown 10 &
server=$!

(
    while sleep "$INTERVAL"; do
        before="$(ytdlp_version)"
        update_ytdlp
        after="$(ytdlp_version)"
        if [ "$before" != "$after" ]; then
            echo "[aria] yt-dlp updated $before -> $after; restarting"
            kill -TERM "$server" 2>/dev/null
            break
        fi
    done
) &
updater=$!

trap 'kill -TERM "$server" 2>/dev/null' TERM INT

# A trapped signal interrupts wait, so keep waiting until the server has exited.
status=0
while kill -0 "$server" 2>/dev/null; do
    wait "$server"
    status=$?
done

kill "$updater" 2>/dev/null
exit "$status"
