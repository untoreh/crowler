# Package

version       = "0.1.0"
author        = "untoreh"
description   = "site"
license       = "MIT"
srcDir        = "src/nim"
installExt    = @["nim"]
bin           = @["cli", "cli_tasks"]
skipdirs      = @["vendor"]
skipFiles     = @["leveldbtool.nim"]

# Dependencies
echo "building... "
requires "nim >= 1.6.0"
requires "karax#master"
# requires "https://github.com/untoreh/nim-sonic-client#master"
# requires "taskpools" # not needed
requires "https://github.com/untoreh/nimpy#master" # required for destructors fix
requires "cligen >= 1.5.23"
requires "lrucache"
# requires "weave#master" # not needed
requires "normalize"
# requires "harpoon" # not needed
# requires "scorper#devel" # not needed
requires "nimterop#master"
requires "parsetoml"
# requires "https://github.com/untoreh/nimdbx" # Use version! not #branch
requires "zstd"
requires "fusion"
requires "minhash"
requires "json_serialization"
# requires "zippy" # not needed
requires "https://github.com/ringabout/Xio" # dep of fsnotify, but `xio` link in nimble index is broken
requires "fsnotify"
requires "zip"
requires "threading"
requires "uuids"
requires "https://github.com/untoreh/nim-chronos#update" # required for proxy support
requires "https://github.com/untoreh/nimSocks#master" # required for proxy support
requires "leveldb"
# requires "asynctools" # not needed
