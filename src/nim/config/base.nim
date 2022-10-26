import os,
       logging,
       uri,
       strutils

const releaseMode* = os.getenv("NIM", "") == "release"
let dockerMode* {.compileTime.} = os.getenv("DOCKER", "") != ""

const PROJECT_PATH* = when releaseMode: ""
                 else: os.getenv("PROJECT_DIR", "")

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

let logLevel = logLevelFromEnv()
const logLevelMacro* = logLevelFromEnv()
proc initLogging*() = setLogFilter(logLevel)
initLogging()
static: echo "cfg: debug level set to: " & $logLevelMacro

export logging

const
    USE_PROXIES* = true
    PROXY_EP* = "socks5://127.0.0.1:8877"
    PROXY_EP_S5* = "socks5://127.0.0.1:8878"
    PROXY_EP_S4* = "socks4://127.0.0.1:8879"
    PROXY_EP_HTTP* = "http://127.0.0.1:8880"
    WEBSITE_DEBUG_PORT* = when releaseMode or dockerMode: "" else: os.getenv("WEBSITE_DEBUG_PORT", ":5050")
    customPages* = ["dmca", "terms-of-service", "privacy-policy"]

proc selectProxy*(n: int): string =
  ## First try without proxies, then with self hosted, then with public
  case n:
    of 0: ""
    of 1: PROXY_EP
    else: PROXY_EP_HTTP
