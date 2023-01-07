import os,
       logging,
       uri,
       strutils

const releaseMode* = os.getenv("NIM", "") == "release"
let dockerMode* {.compileTime.} = os.getenv("DOCKER", "") != ""

const PROJECT_PATH* = os.getenv("PROJECT_DIR", "/site")

let logger* = create(ConsoleLogger)
logger[] = newConsoleLogger(fmtStr = "[$time] - $levelname: ")

proc logLevelFromEnv(): auto =
    case os.getenv("NIM_DEBUG", "INFO").toUpper:
    of "ALL":
        lvlAll
    of "DEBUG":
        lvlDebug
    of "WARNING":
        lvlWarn
    of "ERROR":
        lvlError
    of "CRITICAL":
        lvlFatal
    of "NONE":
        lvlNone
    else:
        lvlInfo

const logLevelMacro* = logLevelFromEnv()
let logLevel* = logLevelFromEnv()
proc initLogging*() = setLogFilter(logLevel)
initLogging()
static: echo "cfg: debug level set to: " & $logLevelMacro

export logging

const WEBSITE_DEBUG_PORT* =
  when releaseMode or dockerMode: ""
  else: ":" & os.getenv("WEBSITE_DEBUG_PORT", "5050")

const BASE_URL* = Uri()
