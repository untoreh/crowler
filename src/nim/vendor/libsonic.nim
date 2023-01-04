import ../cfg
import os

const prefix = when releaseMode: "." else: os.getenv("PROJECT_DIR", "../..")
const libsonic = prefix & "/lib/libsonic_channel.so"


# type Connection* {.incompleteStruct.} = object
type Connection* = pointer

type Vec* = cstringArray

{.push dynlib: libsonic.}
proc consolidate*(conn: Connection) {.importc: "consolidate".}

proc destroy*(ptrx: Connection) {.importc: "destroy".}

proc flush*(conn: Connection, col: ptr char, buc: ptr char, obj: ptr char) {.importc: "flush".}

proc is_open*(conn: Connection): bool {.importc: "is_open".}

proc pushx*(conn: Connection,
            col: ptr char,
            buc: ptr char,
            key: ptr char,
            cnt: ptr char,
            lang: ptr char): bool {.importc: "push".}

proc query*(conn: Connection,
            col: ptr char,
            buc: ptr char,
            kws: ptr char,
            lang: ptr char,
            limit: csize_t): ptr ptr c_char {.importc: "query".}

proc quit*(conn: Connection): bool {.importc: "quit".}

proc sonic_connect*(host: ptr char, pass: ptr char): Connection {.importc: "sonic_connect".}

proc suggest*(conn: Connection,
              col: ptr char,
              buc: ptr char,
              input: ptr char,
              limit: csize_t): ptr ptr c_char {.importc: "suggest".}

proc destroy_response*(arr: ptr ptr char) {.importc: "destroy_response".}

{.pop dynlib: libsonic.}
