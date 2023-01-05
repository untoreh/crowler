#!/usr/bin/env bash
set -e
[ -n "$PROJECT_DIR" ] && cd "$PROJECT_DIR" || cd "$(dirname $0)/../"
if [ "$(realpath $PWD)" != "$(realpath $PROJECT_DIR)" ]; then
    {
        echo "not in project path"
        exit 1
    }
fi

scripts/site.sh -s

rm -f server_data.zip

zip server_data.zip -r data/
rclone copy server_data.zip mega:/server_data.zip
