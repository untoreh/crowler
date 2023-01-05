#!/usr/bin/env bash
set -e

if [ "$(realpath $PWD)" != "$(realpath $PROJECT_DIR)" ]; then
    {
        echo "not in project path"
        exit 1
    }
fi

./cli startServer
