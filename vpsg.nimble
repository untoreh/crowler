# Package

version       = "0.1.0"
author        = "untoreh"
description   = "nim"
license       = "MIT"
srcDir        = "src"
installExt    = @["nim"]
bin           = @["nim"]
skipDirs      = @["nim"]

# Dependencies

requires "nim >= 1.6.0"
