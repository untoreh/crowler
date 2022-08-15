from sonic import IngestClient, SearchClient, ControlClient
import log

is_connected = False
querycl = ingestcl = controlcl = None

def connect(addr, port, psw, reconnect=False):
    import warnings
    warnings.simplefilter("ignore")
    global querycl, ingestcl, controlcl, is_connected
    if not is_connected or reconnect:
        if is_connected:
            disconnect()
        try:
            querycl = SearchClient(addr, port, psw)
            assert querycl.ping()
            ingestcl = IngestClient(addr, port, psw)
            assert ingestcl.ping()
            controlcl = ControlClient(addr, port, psw)
            assert controlcl.ping()
            is_connected = True
            log.debug("sonic: connected to %s:%s", addr, port)
        except:
            is_connected = False
            log.debug("sonic: could not connect to %s:%s", addr, port)

def suggest(*args, **kwargs):
    try:
        return querycl.suggest(*args, **kwargs)
    except Exception as e:
        log.debug("sonic: suggest error %s", e)
        pass

def query(*args, **kwargs):
    try:
        return querycl.query(*args, **kwargs)
    except Exception as e:
        log.debug("sonic: query error %s", e)
        pass

def push(*args, **kwargs):
    try:
        return ingestcl.push(*args, **kwargs)
    except Exception as e:
        log.debug("sonic: push error %s", e)
        pass

def flush(*args, **kwargs):
    try:
        return ingestcl.flush(*args, **kwargs)
    except Exception as e:
        log.debug("sonic: flush error %s", e)
        pass

def trigger(*args, **kwargs):
    try:
        return controlcl.trigger(*args, **kwargs)
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
