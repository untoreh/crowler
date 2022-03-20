import strutils
import nimpy
import re

proc cleanText*(text: string): string {.exportpy.} =
    multireplace(text, [("\n", "\n\n"),
                        ("(.)\1{4,}", "\n\n\1")
                        ])
