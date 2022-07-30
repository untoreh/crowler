import os,
       logging,
       uri,
       strutils

const releaseMode* = os.getenv("NIM", "") == "release"
let dockerMode* {.compileTime.} = os.getenv("DOCKER", "") != ""

const PROJECT_PATH* = when releaseMode: ""
                 else: os.getenv("PROJECT_DIR", "")

let loggerObj = newConsoleLogger(fmtStr = "[$time] - $levelname: ")
let logger* = loggerObj.unsafeAddr

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

let logLevel = logLevelFromEnv()
const logLevelMacro* = logLevelFromEnv()
proc initLogging*() = setLogFilter(logLevel)
initLogging()
static: echo "cfg: debug level set to: " & $logLevelMacro

export logging

const
    USE_PROXIES* = true
    PROXY_EP* = "socks5://localhost:8877"
    WEBSITE_DEBUG_PORT* = when releaseMode or dockerMode: "" else: os.getenv("WEBSITE_DEBUG_PORT", ":5050")
    customPages* = ["dmca", "terms-of-service", "privacy-policy"]
