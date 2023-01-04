
type Connection* {.incompleteStruct.} = object

type Vec* = cstringArray

proc consolidate*(conn: ptr Connection) {.importc: "consolidate".}

proc destroy*(ptrx: ptr Connection) {.importc: "destroy".}

proc flush*(conn: ptr Connection, col: ptr char, buc: ptr char, obj: ptr char) {.importc: "flush".}

proc is_open*(conn: ptr Connection): bool {.importc: "is_open".}

proc pushx*(conn: ptr Connection,
            col: ptr char,
            buc: ptr char,
            key: ptr char,
            cnt: ptr char,
            lang: ptr char): bool {.importc: "push".}

proc query*(conn: ptr Connection,
            col: ptr char,
            buc: ptr char,
            kws: ptr char,
            lang: ptr char,
            limit: csize_t): (ptr ptr c_char) {.importc: "query".}

proc quit*(conn: ptr Connection): bool {.importc: "quit".}

proc sonic_connect*(host: ptr char, pass: ptr char): (ptr Connection) {.importc: "sonic_connect".}

proc suggest*(conn: ptr Connection,
              col: ptr char,
              buc: ptr char,
              input: ptr char,
              limit: csize_t): (ptr ptr c_char) {.importc: "suggest".}

proc destroy_response*(arr: ptr ptr char) {.importc: "destroy_response".}
