#!/usr/bin/env bash

set -e

which envsubst &>/dev/null || { echo envsubst command not found; exit 1; }

[ -z "$CONFIG_NAME" ] && {
    echo need a \$CONFIG_NAME
    exit 1
}

[ ! -e "src/css/app_base.scss" ] && {
    echo template at "src/css/app_base.scss" not found
    exit 1
}

cat src/css/app_base.scss | env -i CONFIG_NAME=$CONFIG_NAME envsubst > src/css/app.scss
