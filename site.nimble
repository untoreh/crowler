# Package

version       = "0.1.0"
author        = "untoreh"
description   = "site"
license       = "MIT"
srcDir        = "src/nim"
installExt    = @["nim"]
bin           = @["cli"]

# Dependencies
echo "building... "
requires "nim >= 1.6.0"
requires "karax#master"
requires "https://github.com/untoreh/nim-sonic-client#master"
requires "taskpools"
requires "https://github.com/untoreh/nimpy#master" # required for destructors fix
requires "cligen >= 1.5.23"
requires "lrucache"
requires "weave#master"
requires "normalize"
requires "scorper#devel"
requires "nimterop#master"
requires "https://github.com/untoreh/nimdbx" # Use version! not #branch
requires "zstd"
requires "fusion"
requires "minhash"
requires "json_serialization"
requires "zippy"
requires "https://github.com/ringabout/Xio" # dep of fsnotify, but `xio` link in nimble index is broken
requires "fsnotify"
requires "zip"
requires "threading"
