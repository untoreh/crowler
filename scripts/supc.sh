#!/usr/bin/env bash

[ -n "$PROJECT_DIR" ] && cd "$PROJECT_DIR" || cd "$(dirname $0)/../"

. .venv/bin/activate

exec supervisorctl -c scripts/supervisor.conf $@
