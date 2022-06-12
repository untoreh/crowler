#!/usr/bin/env bash

set -e
[ $PWD != "${PROJECT_DIR%\/}" ] && { echo "not in project dir."; exit 1; }
[ -z "$1" ] && { echo no site name provided; exit 1; }
site_name="$1"
data_dir="data_$site_name"

if [ ! -e "$data_dir" ]; then
    mkdir -p "$data_dir"
fi
rm -f data
ln -sr "$data_dir" data
