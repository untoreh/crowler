# Package

version       = "0.1.0"
author        = "untoreh"
description   = "wsl"
license       = "MIT"
skipDirs      = @["wslpkg"]
srcDir        = "src/nim"
installExt    = @["nim"]
bin           = @["cli"]

# Dependencies

requires "nim >= 1.6.0"
requires "sonic >= 0.1.0"
requires "nimpy#master"
requires "cligen >= 1.5.23"
requires "lrucache"
requires "weave#master"
requires "normalize"
requires "chronos"
requires "nimterop#master"
requires "https://github.com/untoreh/nimdbx" # Use version! not #branch
requires "zstd"
requires "guildenstern"
requires "fusion"
requires "minhash"
requires "json_serialization"
requires "zippy"
