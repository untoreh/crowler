#!/usr/bin/env bash

set -e
container="server"

docker exec -it $container python src/py/newsite.py "$@"
docker exec -it $container scripts/supc.ch update
docker exec -it $container scripts/supc.ch restart scraper
killall -10 caddy # USR1
