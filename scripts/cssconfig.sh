#!/usr/bin/env bash

set -e

. .venv/bin/activate

[ -z "$CONFIG_NAME" ] && {
    echo need a \$CONFIG_NAME
    exit 1
}

if [ -n "$1" ]; then
    CONFIG_NAME="$1"
fi

template=src/css/colors/template.scss
target_colors=src/css/colors/${CONFIG_NAME}.scss

# [ ! -e "$target_colors" ] && {
#     echo template at "$target_colors" not found
#     exit 1
# }

rm -f src/css/colors.scss
python scripts/color-palette.py
# .
# envsubst < $template > $target_colors
ln -sr "$target_colors" src/css/colors.scss
