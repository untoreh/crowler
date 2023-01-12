#!/usr/bin/env bash

set -e
container="server"

docker exec -it $container python src/py/newsite.py "$@"
docker exec -it $container scripts/supc.sh update
docker exec -it $container scripts/supc.sh restart scraper
# killall -10 caddy # USR1
killall -9 caddy # KILL
