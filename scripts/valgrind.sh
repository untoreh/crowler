#!/usr/bin/env bash

## Ensure DEBUGINFOD_URLS env var is set (at least on arch linux)
## Ensure the packages are updates (pacman -Syu)

# valgrind \
#   --leak-check=full \
#   --show-leak-kinds=all \
#   --track-origins=yes \
#   --verbose \
#   --log-file=valgrind-out.txt \
#   $@

valgrind \
  --tool=massif \
  --verbose \
  --log-file=valgrind-out.txt \
  $@
