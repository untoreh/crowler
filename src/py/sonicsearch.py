from sonic import IngestChannel, SearchChannel, ControlChannel
import log

is_connected = False
querycl: SearchChannel
ingestcl: IngestChannel
controlcl: ControlChannel
c_host = ""
c_pass = ""

def connect(addr="", port="", psw="", reconnect=False):
    import warnings
    warnings.simplefilter("ignore")
    global querycl, ingestcl, controlcl, is_connected, c_host, c_pass
    if not is_connected or reconnect:
        if is_connected:
            disconnect()
        if addr and port:
            c_host = f"{addr}:{port}"
        if psw:
            c_pass = psw
        try:
            querycl = SearchChannel(c_host, c_pass)
            assert querycl.ping()
            ingestcl = IngestChannel(c_host, c_pass)
            assert ingestcl.ping()
            controlcl = ControlChannel(c_host, c_pass)
            assert controlcl.ping()
            is_connected = True
            log.debug("sonic: connected to %s:%s", addr, port)
        except:
            is_connected = False
            log.debug("sonic: could not connect to %s:%s", addr, port)

def suggest(*args, **kwargs):
    try:
        if "lang" in kwargs:
            del kwargs["lang"]
        if "limit" in kwargs:
            del kwargs["limit"]
        return querycl.suggest(*args, **kwargs)
    except Exception as e:
        print(e)
        log.debug("sonic: suggest error %s", e)
        connect(reconnect=True)
        pass

def query(*args, **kwargs):
    try:
        if "lang" in kwargs:
            del kwargs["lang"]
        if "limit" in kwargs:
            del kwargs["limit"]
        return querycl.query(*args, **kwargs)
    except Exception as e:
        print(e)
        log.debug("sonic: query error %s", e)
        connect(reconnect=True)
        pass

def push(*args, **kwargs):
    try:
        if "lang" in kwargs:
            del kwargs["lang"]
        return ingestcl.push(*args, **kwargs)
    except Exception as e:
        log.debug("sonic: push error %s", e)
        pass

def flush(*args, **kwargs):
    try:
        if "lang" in kwargs:
            del kwargs["lang"]
        if "obj" in kwargs:
            return ingestcl.flusho(*args, **kwargs)
        elif "bucket" in kwargs:
            return ingestcl.flushb(*args, **kwargs)
        else:
            return ingestcl.flushc(*args, **kwargs)
    except Exception as e:
        log.debug("sonic: flush error %s", e)
        pass

def consolidate(*args, **kwargs):
    try:
        return controlcl.consolidate(*args, **kwargs)
    except Exception as e:
        log.debug("sonic: trigger error %s", e)
        pass

def quit(c):
    try:
        c.quit()
    except:
        pass


def disconnect():
    try:
        quit(querycl)
        quit(ingestcl)
        quit(controlcl)
    except:
        pass
    global is_connected
    is_connected = False

def isopen():
    return querycl.ping()

import atexit

atexit.register(disconnect)
