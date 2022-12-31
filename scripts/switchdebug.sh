#!/usr/bin/env bash

trg="$1"
[ -n "$trg" ] || { echo "provide the target directory containing 'nim.cfg' debug/release files. "; exit 1; }

if [ "$NIM" = debug -a -e $trg/nim.cfg.debug ]; then
    echo "Switching to debug nim.cfg"
    off=".release"
    on=".debug"
elif [ -e $trg/nim.cfg.release ]; then
    echo "Switching to release nim.cfg"
    off=".debug"
    on=".release"
fi

set -x
if [ ! -e "$trg/nim.cfg$off" ]; then
    mv $trg/nim.cfg{,$off}
fi
if [ -n "$on" ]; then
    mv $trg/nim.cfg{$on,}
fi
