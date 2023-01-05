#!/usr/bin/env bash

DIR=$(realpath "$1")
shift

[ "$(realpath $DIR)" != "$(realpath $PROJECT_DIR)" ] && { echo script directory "($DIR)" is not "$PROJECT_DIR".; exit 1; }

cd $DIR

[ -e .venv/bin/activate ] && . .venv/bin/activate

cd src/py

export PYTHON_DEBUG="${1:-info}"
shift

python main.py $@
