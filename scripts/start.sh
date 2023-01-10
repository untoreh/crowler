#!/usr/bin/env bash
set -e
[ -e $PROJECT_DIR/.venv/bin/activate ] && . $PROJECT_DIR/.venv/bin/activate

mkdir -p $PROJECT_DIR/config/supervisor.d
exec supervisord -n -c $PROJECT_DIR/config/supervisor.conf
