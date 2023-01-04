#!/usr/bin/env sh

cargo build --lib --release  --manifest-path ./Cargo.toml
# nbindgen src/main.rs > libsonic.nim
# mv libsonic.nim ../../nim/
