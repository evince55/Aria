#!/bin/sh
# Creates backend/.env with a new API key and, if you have one, your tunnel token.
set -eu

cd "$(dirname "$0")"

if [ -e .env ]; then
    echo "backend/.env already exists, so nothing was changed." >&2
    echo "Delete it first to start over. That also replaces your API key." >&2
    exit 1
fi

if ! key="$(openssl rand -hex 32)"; then
    echo "openssl is needed to generate an API key." >&2
    exit 1
fi

echo "Paste your Cloudflare Tunnel token, or press Return to skip the tunnel:"
token=""
IFS= read -r token || true

umask 077
{
    echo "ARIA_API_KEY=$key"
    if [ -n "$token" ]; then
        echo "TUNNEL_TOKEN=$token"
        echo "COMPOSE_PROFILES=tunnel"
    fi
} > .env

echo
echo "Created backend/.env. Enter this API key in Aria under More -> Backend:"
echo
echo "  $key"
echo
echo "Keep it private. To start the server, run: docker compose up -d --build"
