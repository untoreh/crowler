#!/usr/bin/env sh
#
PORT=${SITE_PORT:-5050}
HOST="http://localhost"
BIN=cli

if ! timeout 15 curl --fail "${HOST}:${PORT}" --output /dev/null; then
   pkill -x cli
fi
