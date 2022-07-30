#!/usr/bin/env bash

set -e

. .venv/bin/activate


if [ "$1" == "-b" ]; then
    dobuild=yes
    shift
fi

[ -z "$CONFIG_NAME" -a -z "$1" ] && {
    echo need a \$CONFIG_NAME
    exit 1
}

if [ -n "$1" ]; then
    export CONFIG_NAME="$1"
fi

template=src/css/colors/template.scss
target_colors=src/css/colors/${CONFIG_NAME}.scss

# [ ! -e "$target_colors" ] && {
#     echo template at "$target_colors" not found
#     exit 1
# }

rm -f src/css/colors.scss
# wsl config is preset
python scripts/color-palette.py
ln -sr "$target_colors" src/css/colors.scss
if [ -n "$dobuild" ]; then
    npm run build
fi
