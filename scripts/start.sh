#!/usr/bin/env bash
set -e
[ -e $PROJECT_DIR/.venv/bin/activate ] && . $PROJECT_DIR/.venv/bin/activate

exec supervisord -n -c $PROJECT_DIR/config/supervisor.conf
