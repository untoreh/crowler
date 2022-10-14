import
    std/deques,
    times
import
    utils,
    quirks,
    cfg,
    types,
    translate_db

let monitorCache* = initDeque[Time](1000)

for
