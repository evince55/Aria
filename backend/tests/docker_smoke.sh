#!/usr/bin/env bash
# End-to-end check of backend/compose.yaml on a machine with Docker. CI runs it.
# It makes no YouTube requests, because runners have data-center IP addresses.
#
#   bash backend/tests/docker_smoke.sh
#
# SMOKE_RESTART_DOCKER=1 also restarts the Docker daemon, to simulate a reboot.
# Only use that on a disposable machine.
set -euo pipefail

cd "$(dirname "$0")/.."

PORT="${SMOKE_PORT:-18000}"
BASE="http://127.0.0.1:$PORT"
KEY="$(openssl rand -hex 32)"
ENV_FILE="$(mktemp)"
LOGS="$(mktemp)"
QUICK_TUNNEL=""
TUNNEL_IMAGE="$(sed -n 's/^ *image: \(cloudflare\/cloudflared:.*\)$/\1/p' compose.yaml)"

cat > "$ENV_FILE" <<EOF
ARIA_API_KEY=$KEY
ARIA_LOCAL_PORT=$PORT
YTDLP_UPDATE_INTERVAL_SECONDS=20
EOF

dc() { docker compose -p aria-smoke --env-file "$ENV_FILE" "$@"; }

cleanup() {
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "--- backend logs"
        dc logs --no-color --tail 60 backend || true
    fi
    [ -n "$QUICK_TUNNEL" ] && docker rm -f "$QUICK_TUNNEL" >/dev/null 2>&1
    dc down -v --remove-orphans >/dev/null 2>&1 || true
    rm -f "$ENV_FILE" "$LOGS"
    exit "$status"
}
trap cleanup EXIT

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1" >&2; exit 1; }

http_code() { curl -s -o /dev/null -w '%{http_code}' -m 10 "$@"; }

expect_code() {
    local want="$1" label="$2"; shift 2
    local got; got="$(http_code "$@" || true)"
    [ "$got" = "$want" ] || fail "$label: expected $want, got $got"
    pass "$label"
}

health_field() {
    curl -fsS -m 10 "$BASE/api/health" | python3 -c "import json,sys;print(json.load(sys.stdin)$1)"
}

wait_for_health() {
    local i
    for i in $(seq 1 90); do
        curl -fsS -m 3 "$BASE/api/health" >/dev/null 2>&1 && return 0
        sleep 2
    done
    return 1
}

in_backend() { dc exec -T backend "$@"; }

echo "== Refuses to run without a key"
if ARIA_API_KEY='' docker compose -p aria-smoke --env-file /dev/null config >/dev/null 2>&1; then
    fail "compose accepted a missing ARIA_API_KEY"
fi
pass "compose rejects a missing key"

dc build --quiet backend
echo "Image size: $(docker image inspect -f '{{.Size}}' aria-backend:local) bytes"
for bad in "" "too-short"; do
    if docker run --rm -e ARIA_API_KEY="$bad" aria-backend:local >/dev/null 2>&1; then
        fail "image started with key '$bad'"
    fi
done
pass "image rejects an empty or short key"

echo "== Starts and reports healthy"
dc pull --quiet network
dc --profile tunnel pull --quiet cloudflared
pass "pinned images exist for this architecture"
dc up -d --wait backend
[ "$(health_field "['status']")" = "ok" ] || fail "health status"
[ "$(health_field "['node']['available']")" = "True" ] || fail "node not detected by app"
pass "health is ok and the app found node"

echo "== Runtime contents"
[ "$(in_backend id -u)" = "10001" ] || fail "not running as the aria user"
pass "runs as a non-root user"
in_backend ffmpeg -version >/dev/null || fail "ffmpeg missing"
in_backend ffprobe -version >/dev/null || fail "ffprobe missing"
node_major="$(in_backend node -p 'process.versions.node.split(".")[0]')"
[ "$node_major" -ge 20 ] || fail "node $node_major is too old"
in_backend python -c "import yt_dlp, yt_dlp_ejs, sqlite_vec" || fail "python packages missing"
pass "ffmpeg, node $node_major, yt-dlp, yt-dlp-ejs and sqlite-vec are present"

echo "== Authentication"
expect_code 401 "no key is rejected" "$BASE/api/search?q=x"
expect_code 401 "wrong key is rejected" -H "X-API-Key: wrong" "$BASE/api/search?q=x"
expect_code 200 "correct key is accepted" -H "X-API-Key: $KEY" \
    "$BASE/api/library/query?device_id=00000000-0000-4000-8000-000000000000&q=x"

echo "== Client IP trust"
# Same namespace as cloudflared: the backend should believe the header.
in_backend python -c "
import urllib.request, urllib.error
r = urllib.request.Request('http://localhost:8000/api/search?q=x', headers={'CF-Connecting-IP': '203.0.113.7'})
try: urllib.request.urlopen(r, timeout=5)
except urllib.error.HTTPError: pass
"
# From outside: a forged header must be ignored.
http_code -H "CF-Connecting-IP: 203.0.113.8" "$BASE/api/search?q=x" >/dev/null || true
sleep 1
dc logs --no-color backend > "$LOGS"
grep -q "ip=203.0.113.7 " "$LOGS" || fail "header ignored from inside the namespace"
pass "client IP header is trusted over shared localhost"
if grep -q "ip=203.0.113.8 " "$LOGS"; then fail "forged header trusted from outside"; fi
pass "forged client IP header is ignored from outside"
if grep -q "$KEY" "$LOGS"; then fail "API key appeared in logs"; fi
pass "API key is not in the logs"

echo "== Cloudflare tunnel, using a temporary quick tunnel (best effort)"
network_id="$(dc ps -q network)"
QUICK_TUNNEL="$(docker run -d --network "container:$network_id" "$TUNNEL_IMAGE" \
    tunnel --no-autoupdate --url http://localhost:8000)"
url=""
for _ in $(seq 1 30); do
    url="$(docker logs "$QUICK_TUNNEL" 2>&1 | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | head -1 || true)"
    [ -n "$url" ] && break
    sleep 2
done
tunnel_ok=""
if [ -n "$url" ]; then
    for _ in $(seq 1 20); do
        if [ "$(http_code "$url/api/search?q=x" || true)" = "401" ]; then tunnel_ok=1; break; fi
        sleep 3
    done
fi
docker rm -f "$QUICK_TUNNEL" >/dev/null 2>&1; QUICK_TUNNEL=""
if [ -n "$tunnel_ok" ]; then
    sleep 1
    dc logs --no-color backend > "$LOGS"
    line="$(grep 'GET /api/search -> 401' "$LOGS" | tail -1)"
    case "$line" in
        *" ip=127.0.0.1 "*|*" ip=::1 "*) fail "client IP was lost through the tunnel" ;;
    esac
    pass "HTTPS through Cloudflare reaches the backend, with the real client IP"
else
    echo "SKIP  quick tunnel was unavailable"
fi

echo "== Data survives recreating the containers"
in_backend python -c "open('song_cache/smokeID0000.bestaudio.m4a','wb').write(b'A'*32768)"
dc down
dc up -d --wait backend
[ "$(in_backend sh -c 'wc -c < song_cache/smokeID0000.bestaudio.m4a')" = "32768" ] \
    || fail "cache file was lost"
pass "the cache volume persisted"

echo "== yt-dlp update restarts the backend, and the namespace survives"
network_before="$(docker inspect -f '{{.State.StartedAt}}' "$(dc ps -q network)")"
backend_before="$(docker inspect -f '{{.State.StartedAt}}' "$(dc ps -q backend)")"
latest="$(health_field "['yt_dlp_version']")"
in_backend pip install --quiet --disable-pip-version-check 'yt-dlp==2026.6.9'
restarted=""
for _ in $(seq 1 60); do
    sleep 3
    version="$(health_field "['yt_dlp_version']" 2>/dev/null || true)"
    backend_now="$(docker inspect -f '{{.State.StartedAt}}' "$(dc ps -q backend)")"
    if [ "$backend_now" != "$backend_before" ] && [ "$version" = "$latest" ]; then
        restarted=1; break
    fi
done
[ -n "$restarted" ] || fail "backend did not update and restart"
pass "an older yt-dlp was updated to $latest and the server restarted"
[ "$(docker inspect -f '{{.State.StartedAt}}' "$(dc ps -q network)")" = "$network_before" ] \
    || fail "network namespace owner restarted"
pass "the shared network namespace was not disturbed"
expect_code 401 "the backend is reachable after its restart" "$BASE/api/search?q=x"

if [ "${SMOKE_RESTART_DOCKER:-0}" = "1" ]; then
    echo "== Comes back after a Docker daemon restart"
    sudo systemctl restart docker
    wait_for_health || fail "backend did not return after the daemon restart"
    expect_code 401 "authentication still works after the daemon restart" "$BASE/api/search?q=x"
    in_backend python -c "
import urllib.request
urllib.request.urlopen('http://localhost:8000/api/health', timeout=5)
" || fail "backend lost its shared localhost after the daemon restart"
    pass "the shared namespace works after the daemon restart"
fi

echo "All checks passed."
