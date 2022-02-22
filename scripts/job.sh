#!/usr/bin/env bash

DIR=$(realpath "$1")
shift

[ "$(basename $DIR)" != wsl ] && { echo script directory "($DIR)" is not wsl.; exit 1; }

cd $DIR/

. .venv/bin/activate

cd src/py

export PYTHON_DEBUG="${1:-info}"
shift

python main.py $@
