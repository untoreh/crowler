#!/usr/bin/env bash

[ -n "$PROJECT_DIR" ] && cd "$PROJECT_DIR" || cd "$(dirname $0)/../"

[ -e .venv/bin/activate ] && . .venv/bin/activate

exec supervisorctl -c config/supervisor.conf $@
