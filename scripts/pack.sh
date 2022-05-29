#!/usr/bin/env bash
set -e
[ -n "$PROJECT_DIR" ] && cd "$PROJECT_DIR" || cd "$(dirname $0)/../"
if [ "$(basename $PWD)" != "wsl" ]; then
    {
        echo "not in project path"
        exit 1
    }
fi

. .venv/bin/activate
scripts/site.sh -s
rm -f wsl.zip

zip wsl.zip -r \
    data/ \
    site/assets \
    wsl-cli \
    run/ \
    lib/py \
    lib/vendor/imageflow.dist/libimageflow.so \
    scripts/ \
    requirements.txt
