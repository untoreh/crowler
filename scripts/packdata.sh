#!/usr/bin/env bash
set -e
[ -n "$PROJECT_DIR" ] && cd "$PROJECT_DIR" || cd "$(dirname $0)/../"
if [ "$(basename $PWD)" != "wsl" ]; then
    {
        echo "not in project path"
        exit 1
    }
fi

scripts/site.sh -s

rm -f wsl_data.zip

zip wsl_data.zip -r data/
rclone copy wsl_data.zip mega:/wsl_data.zip
