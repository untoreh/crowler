#!/usr/bin/env bash
#
. ~/.profile

type pastel &>/dev/null || { echo "'pastel' command not found"; exit 1; }

hostlist=${1:-hostips.txt}
[ -e $hostlist ] || { echo "hostlist file $hostlist not found"; exit 1; }
pastel paint magenta "reading ips from $hostlist..."

successlist="${hostlist}_success.txt"
touch "$successlist"
all=$(cat $hostlist | wc -l)
checked=$(cat $successlist | wc -l)

checker=http://api.ipify.org
tunnel_port=8899
if [ -n "$2" ]; then
    tunnel_proto_cred=$2
elif [ $hostlist = "hostips.txt" ]; then
    tunnel_proto_cred="ss+quic://aes-128-cfb:128"
elif [ $hostlist = "torips.txt" ]; then
    tunnel_proto_cred="ss+quic://aes-128-cfb:tpass123"
else
    echo tunnel protocol and credentials not specified for hostlist "$hostlist"
    exit 1
fi

endpoints=()
while read l; do
    endpoints+=($l)
done < <(diff -w <(sort $successlist) <(sort $hostlist) | grep '>' | sed 's/> //')
pastel paint green "checking hosts ($checked / $all)"

trap "kill %1 &>/dev/null" EXIT TERM KILL

for p in ${endpoints[@]}; do
    p=$(echo -n "$p" | tr -d '\n' | tr -d '\r')
    lingering="$(fuser $tunnel_port/tcp 2>/dev/null)"
    [ -n "$lingering" ] && kill $lingering
    gstcmd="gost -L :$tunnel_port -F $tunnel_proto_cred@$p"
    $gstcmd 2>/dev/null &
    while ! timeout 1 bash -c "echo > /dev/tcp/localhost/$tunnel_port" &>/dev/null; do
        sleep 0.1
    done
    pastel paint cyan -n "checking connection to $p "
    cmd="curl -s --proxy socks5://localhost:$tunnel_port $checker"
    res="$($cmd)"
    if [ $? != 0 ]; then
        echo
	    disown %1
        echo "$res"
        pastel paint red failed to connect to $p
        pastel paint yellow "$gstcmd"
        pastel paint yellow "$cmd"
    else
        pastel paint green OK
        echo "$p" >> $successlist
    fi
    kill %1 &>/dev/null
done
