import urllib.request , socket
import random
from urllib.parse import urlparse

JUDGES=["http://mojeip.net.pl/asdfa/azenv.php", "http://www.proxy-listen.de/azenv.php", "http://proxyjudge.us"]
JUDGES_OK = None

def validate_judges():
    for j in JUDGES:
        try:
            code = urllib.request.urlopen(j).getcode()
            if code != 200:
                JUDGES.remove(j)
        except:
            JUDGES.remove(j)
    if len(JUDGES) == 0:
        raise RuntimeError("No judges available for proxy checking")

def set_socket_timeout(timeout):
    socket.setdefaulttimeout(timeout)

set_socket_timeout(5)

def check_proxy(proxy, timeout, verbose=False):
    if JUDGES_OK is None:
        validate_judges()
    try:
        pr = urlparse(proxy)
        proxy_handler = urllib.request.ProxyHandler({pr.scheme: proxy})
        opener = urllib.request.build_opener(proxy_handler)
        opener.addheaders = [('User-agent', 'Mozilla/5.0')]
        urllib.request.install_opener(opener)
        sock=urllib.request.urlopen(random.choice(JUDGES))  # change the url address here
        #sock=urllib.urlopen(req)
    except urllib.error.HTTPError as e:
        if verbose:
            print('Error code: ', e.code)
        return False
    except Exception as detail:
        if verbose:
            print( "ERROR:", detail)
        return True
    return True
