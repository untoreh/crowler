import strutils,
       nimpy,
       nre,
       nimpy/py_lib {.all.},
       dynlib,
       weave

proc cleanText*(text: string): string {.exportpy.} =
    multireplace(text, [("\n", "\n\n"),
                        ("(.)\1{4,}", "\n\n\1")
                        ])
