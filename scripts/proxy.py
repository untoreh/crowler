#!/usr/bin/env python3
import subprocess as sp
import json

filename="pbproxies"
limit=100
typemap = {
    "CONNECT:80": "http",
    "CONNECT:25": "http",
    "HTTP": "http",
    "SOCKS4": "socks4",
    "SOCKS5": "socks5"
}
types=" ".join(list(typemap.keys()))
cmd=f"proxybroker find -o {filename}.json -f json --types {types} -l {limit}".split()
sp.run(cmd)

with open(f"{filename}.json", "r") as f:
    proxies = json.load(f)

hf=open(f"{filename}_http.txt", "w")
s4=open(f"{filename}_s4.txt", "w")
s5=open(f"{filename}_s5.txt", "w")
filemap = {
    "CONNECT:80": hf,
    "CONNECT:25": hf,
    "HTTP": hf,
    "SOCKS5": s5,
    "SOCKS4": s4,
}
for p in proxies:
    host = p["host"]
    port = p["port"]
    types = p["types"]
    for t in types:
        tp = t["type"]
        tpm = typemap[tp]
        filemap[tp].write(f"{host}:{port}\n")
