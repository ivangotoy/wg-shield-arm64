#!/usr/bin/env bash
# WG Shield Arm64 - offline test harness (Linux PC, no phone, no root).
#
# Runs the module's own scripts inside a private user + network namespace
# (unshare -n --map-auto, else -rn: uid 0 and CAP_NET_ADMIN there, nothing
# outside is touched).
# netd is imitated with its rules (16000 explicit network, 31000 default
# network) and a table per network; the tunnel link is a veth
# (WGS_LINKTYPE), the handshake comes from $STATE/fake_hs. Android tools
# (getprop, dumpsys, pm, ping, su, cmd) are small fakes.
#
#   bash tests/harness.sh            run every case
#   bash tests/harness.sh -k NAME    run the cases whose name contains NAME
#   WGS_TEST_BB=/path/busybox bash tests/harness.sh   the same with busybox ash
#   WGS_TEST_SH=/path/mksh bash tests/harness.sh      the same with mksh (the
#                                     WebUI's shell; host tools for applets)
#
# Scratch goes to tests/.run (ext4 next to the repo), removed at the start.
set -u
REPO=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
if [ "${WGS_IN_NS:-}" != 1 ]; then
    command -v unshare >/dev/null || { echo "unshare (util-linux) is needed"; exit 2; }
    command -v ip >/dev/null || { echo "ip (iproute2) is needed"; exit 2; }
    # --map-auto maps the subuid range too: netd-style uidrange rules (5014)
    # need the uids to exist in the namespace; without it they are refused
    if unshare -n --map-auto --map-root-user true 2>/dev/null; then
        exec env WGS_IN_NS=1 WGS_UIDS=1 unshare -n --map-auto --map-root-user bash "$0" "$@"
    fi
    exec env WGS_IN_NS=1 unshare -rn bash "$0" "$@"
fi
FILTER=""; [ "${1:-}" = -k ] && FILTER=${2:-}
# WGS_TEST_BB=/path/to/busybox: run the scripts with busybox ash and its
# applets (unzip, gzip, ...) like KernelSU does; default: bash + host tools
TSH=$(command -v bash)
[ -n "${WGS_TEST_BB:-}" ] && TSH="$WGS_TEST_BB sh"
[ -n "${WGS_TEST_SH:-}" ] && TSH=$WGS_TEST_SH

RUN="$REPO/tests/.run"
rm -rf "$RUN"; mkdir -p "$RUN"
FAKES="$RUN/fakes"; mkdir -p "$FAKES"

# ---- fakes ---------------------------------------------------------------------
cat > "$FAKES/getprop" <<'EOF'
#!/bin/sh
case "$1" in sys.boot_completed) echo 1 ;; debug.tracing.screen_state) echo 2 ;; esac
EOF
# dumpsys connectivity: one line per network in $RUN/networks ("<netId> <caps>")
cat > "$FAKES/dumpsys" <<EOF
#!/bin/sh
[ "\$1" = connectivity ] || exit 0
while read -r n c; do echo "  NetworkAgentInfo{network{\$n}  handle{1}  ni{X CONNECTED}  nc{[ Transports: WIFI Capabilities: \$c LinkUpBandwidth>=1Kbps ]}"; done < "$RUN/networks"
EOF
echo "100 INTERNET&NOT_RESTRICTED&TRUSTED&VALIDATED" > "$RUN/networks"
printf '#!/bin/sh\necho "package:com.android.captiveportallogin uid:10050"\n' > "$FAKES/pm"
printf '#!/bin/sh\nexit 1\n' > "$FAKES/ping"
printf '#!/bin/sh\nexit 0\n' > "$FAKES/su"
printf '#!/bin/sh\nexit 0\n' > "$FAKES/cmd"
# iptables: the rules as "-A CHAIN ..." lines in $WGS_IPT_DIR/<table>
# (exact text match for -C / -D, chains with -N; enough for the DNS chain)
cat > "$FAKES/iptables" <<'EOF'
#!/bin/sh
[ "$1" = -w ] && shift
t=filter; [ "$1" = -t ] && { t=$2; shift 2; }
mkdir -p "$WGS_IPT_DIR"; f="$WGS_IPT_DIR/$t"; touch "$f"
op=$1; ch=$2; shift 2; r="-A $ch $*"; r=${r% }
has() { grep -qx -- "-N $ch" "$f"; }
case "$op" in
    -N) has && exit 1; echo "-N $ch" >> "$f" ;;
    -F) has || exit 1; grep -v -- "^-A $ch " "$f" > "$f.n"; mv "$f.n" "$f" ;;
    -X) has || exit 1; grep -q -- "^-A $ch " "$f" && exit 1; grep -q -- "-j $ch\$" "$f" && exit 1
        grep -vx -- "-N $ch" "$f" > "$f.n"; mv "$f.n" "$f" ;;
    -A) [ "$ch" = OUTPUT ] || has || exit 1; echo "$r" >> "$f" ;;
    -C) grep -qxF -- "$r" "$f" ;;
    -D) grep -qxF -- "$r" "$f" || exit 1
        awk -v l="$r" '!d && $0 == l { d = 1; next } { print }' "$f" > "$f.n"; mv "$f.n" "$f" ;;
    -S) has || exit 1; grep -- "^-A $ch " "$f" ;;
    *) exit 2 ;;
esac
EOF
chmod 755 "$FAKES"/*

# ---- module copy (module_desc rewrites module.prop: never the repo's) ----------
MOD="$RUN/module"
mkdir -p "$MOD"
cp -r "$REPO"/sh "$REPO"/*.sh "$REPO"/module.prop "$MOD"/

export WGS_MODDIR="$MOD" WGS_DATA="$RUN/data" WGS_ADB="$RUN/adb" WGS_MODULES="$RUN/adb/modules"
export WGS_BACKUP_ROOT="$RUN/sdcard/wg-shield" WGS_DL="$RUN/sdcard/Download"
export WGS_IP="$(command -v ip)" WGS_BB="${WGS_TEST_BB:-$RUN/no-busybox}" WGS_RT_TABLES="$RUN/rt_tables"
export WGS_GETPROP="$FAKES/getprop" WGS_DUMPSYS="$FAKES/dumpsys" WGS_PM="$FAKES/pm"
export WGS_PING="$FAKES/ping" WGS_SU="$FAKES/su" WGS_CMD="$FAKES/cmd"
export WGS_LINKTYPE=veth WGS_PROC6="$RUN/proc6" WGS_SYSNET="$RUN/sysnet"
export WGS_SH="$TSH" WGS_HEAL_WAIT=1
export WGS_IPT="$FAKES/iptables" WGS_IPT_DIR="$RUN/ipt"
STATE="$WGS_DATA/state"
mkdir -p "$WGS_MODULES" "$WGS_DL" "$WGS_PROC6/all"
echo 1 > "$WGS_PROC6/all/disable_ipv6"          # no IPv6 on the fake phone
printf '%s\n' "97 local_network" "1028 wlan0" > "$WGS_RT_TABLES"

# ---- the fake network: wlan0 (netId 100 = 0x64), netd's rules ------------------
ip link set lo up
ip link add wlan0 type veth peer name wlan0p && ip link set wlan0p up && ip link set wlan0 up
ip addr add 192.168.1.50/24 dev wlan0
ip route add 192.168.1.0/24 dev wlan0 table 1028
ip route add default via 192.168.1.1 dev wlan0 table 1028
ip rule add pref 16000 fwmark 0x10064/0x1ffff iif lo lookup 1028
ip rule add pref 31000 fwmark 0x0/0xffff iif lo lookup 1028
# netd drops what no rule took (unreachable at the end of its chain)
ip rule add pref 32000 unreachable

ctl() { $TSH "$MOD/ctl.sh" "$@"; }
kv() { sed -n "s/^$1=\\([0-9]*\\)\$/\\1/p"; }   # numeric key=value only
st() { sed -n "s/^$1=//p" "$STATE/status" 2>/dev/null; }
# where an app's unbound socket goes: "wgs0", "wlan0" or "blocked"
route_of() {
    r=$(ip route get 1.1.1.1 2>&1 | head -n1)
    case "$r" in *"dev wgs0"*) echo wgs0 ;; *"dev wlan0"*) echo wlan0 ;; *) echo blocked ;; esac
}
conf() {  # conf FILE ENDPOINT
    cat > "$1" <<EOF
[Interface]
PrivateKey = yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=
Address = 10.2.0.2/32
DNS = 10.2.0.1

[Peer]
PublicKey = xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=
AllowedIPs = 0.0.0.0/0
Endpoint = $2
EOF
}
reset_state() {
    ctl down >/dev/null 2>&1
    ctl removeall >/dev/null 2>&1
    rm -rf "$WGS_DATA"
}

PASS=0; FAILN=0
check() {  # check DESCRIPTION EXPECTED ACTUAL
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); echo "  ok   $1"
    else FAILN=$((FAILN + 1)); echo "  FAIL $1: expected '$2', got '$3'"; fi
}
want() { [ -z "$FILTER" ] || case "$1" in *"$FILTER"*) return 0 ;; *) return 1 ;; esac; }

# ---- cases -----------------------------------------------------------------------
if want basic; then
    echo "basic: import, up, handshake, kill switch, down"
    reset_state
    conf "$WGS_DL/wg-BG-1.conf" 203.0.113.10:51820
    check "import" 1 "$(ctl import wg-BG-1.conf | kv imported)"
    check "direct before up" wlan0 "$(route_of)"
    ctl up wg-BG-1 >/dev/null
    check "state after up (no handshake yet)" handshaking "$(st state)"
    check "traffic into the tunnel" wgs0 "$(route_of)"
    date +%s > "$STATE/fake_hs"
    ctl status >/dev/null
    check "state with a handshake" up "$(st state)"
    ip link set wgs0 down
    ip route del default dev wgs0 table 51820 2>/dev/null
    check "kill switch backstop while wgs0 has no route" blocked "$(route_of)"
    ctl status >/dev/null
    check "routes repaired by a tick" wgs0 "$(route_of)"
    ctl down >/dev/null
    check "state after down" off "$(st state)"
    check "direct after down" wlan0 "$(route_of)"
fi

if want killswitch_off; then
    echo "killswitch_off: down tunnel goes direct"
    reset_state
    conf "$WGS_DL/wg-NL-1.conf" 203.0.113.11:51820
    ctl import wg-NL-1.conf >/dev/null
    ctl set killswitch 0 >/dev/null
    ctl up wg-NL-1 >/dev/null
    check "handshaking + kill switch off = direct" wlan0 "$(route_of)"
    ctl set killswitch 1 >/dev/null
    check "kill switch on = through the tunnel" wgs0 "$(route_of)"
fi

if want validate; then
    echo "validate: endpoint and address checks"
    reset_state
    for ep in 203.0.113.1:0 203.0.113.1:65536 203.0.113.1:99999 999.1.1.1:51820 1.2.3:51820 1.2.3.4.5:51820; do
        conf "$WGS_DL/bad.conf" "$ep"
        check "endpoint $ep refused" 0 "$(ctl import bad.conf | kv imported)"
    done
    conf "$WGS_DL/ok.conf" 203.0.113.1:65535
    check "endpoint port 65535 accepted" 1 "$(ctl import ok.conf | kv imported)"
    conf "$WGS_DL/host.conf" vpn.example.com:51820
    check "host name endpoint accepted" 1 "$(ctl import host.conf | kv imported)"
    conf "$WGS_DL/addr.conf" 203.0.113.1:51820
    sed -i 's#^Address = .*#Address = 10.2.0.300/32#' "$WGS_DL/addr.conf"
    check "address 10.2.0.300 refused" 0 "$(ctl import addr.conf | kv imported)"
    sed -i 's#^Address = .*#Address = 10.2.0.2/33#' "$WGS_DL/addr.conf"
    check "address prefix /33 refused" 0 "$(ctl import addr.conf | kv imported)"
    sed -i 's#^Address = .*#Address = 10.2.0.2/24, fd00::2/128#' "$WGS_DL/addr.conf"
    check "address /24 + IPv6 accepted" 1 "$(ctl import addr.conf | kv imported)"
fi

if want zipslip; then
    echo "zipslip: an export zip cannot write outside the import folder"
    reset_state
    if command -v python3 >/dev/null; then
        conf "$RUN/inner.conf" 203.0.113.12:51820
        python3 -I - "$WGS_DL/evil.zip" "$RUN/inner.conf" <<'EOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.write(sys.argv[2], "../../../../escaped.conf")
    z.write(sys.argv[2], "a/../../../../mid.conf")
EOF
        ctl import evil.zip >/dev/null 2>&1
        check "nothing written outside tunnels/" "" "$(find "$RUN" \( -name escaped.conf -o -name mid.conf \) -not -path "$WGS_DATA/tunnels/*")"
    else
        echo "  skip (python3 missing)"
    fi
fi

if want lock; then
    echo "lock: settings changes wait for the watchdog's lock"
    reset_state
    conf "$WGS_DL/wg-DE-1.conf" 203.0.113.13:51820
    ctl import wg-DE-1.conf >/dev/null
    ctl up wg-DE-1 >/dev/null
    # a tick in progress: the lock is held by a live process
    sleep 30 & holder=$!
    mkdir "$STATE/lock" && echo "$holder" > "$STATE/lock/pid"
    ctl down >/dev/null 2>&1 & c=$!
    sleep 2
    check "settings untouched while the lock is held" wg-DE-1 "$(sed -n 's/^ACTIVE=//p' "$WGS_DATA/settings.conf")"
    rm -rf "$STATE/lock"; kill "$holder" 2>/dev/null; wait "$c"
    check "down applied once the lock is free" "" "$(sed -n 's/^ACTIVE=//p' "$WGS_DATA/settings.conf")"
    check "state off" off "$(st state)"
    check "lock released by ctl" no "$([ -d "$STATE/lock" ] && echo yes || echo no)"
    # a failing command under the lock must not leave it behind
    ctl set killswitch 7 >/dev/null 2>&1
    ctl up no-such-tunnel >/dev/null 2>&1
    check "lock released after a failed command" no "$([ -d "$STATE/lock" ] && echo yes || echo no)"
fi

if want backup; then
    echo "backup: zip written, checked, restored"
    reset_state
    conf "$WGS_DL/wg-BG-2.conf" 203.0.113.14:51820
    conf "$WGS_DL/wg-BG-3.conf" 203.0.113.15:51820
    ctl import wg-BG-2.conf >/dev/null; ctl import wg-BG-3.conf >/dev/null
    ctl fav add wg-BG-3 >/dev/null
    check "backup" 2 "$(ctl backup | kv backed_up)"
    check "zip readable by unzip" 0 "$(unzip -tq "$WGS_BACKUP_ROOT/wg-shield-backup.zip" >/dev/null 2>&1; echo $?)"
    ctl removeall >/dev/null
    out=$(ctl restore)
    check "restore imported" 2 "$(echo "$out" | kv imported)"
    check "restore favorites" 1 "$(echo "$out" | kv favorites)"
fi

# tick until the status key has the value (at most N ticks, 1.1 s apart)
tick_until() {  # tick_until KEY VALUE N
    _n=0
    while [ "$_n" -lt "$3" ]; do
        ctl status >/dev/null 2>&1
        [ "$(st "$1")" = "$2" ] && return 0
        sleep 1.1; _n=$((_n + 1))
    done
    return 1
}
setting() { sed -n "s/^$1=//p" "$WGS_DATA/settings.conf"; }

if want heal; then
    echo "heal: restarts, then auto-switch skips the failed server address"
    reset_state
    conf "$WGS_DL/wg-BG-1.conf" 203.0.113.21:51820
    conf "$WGS_DL/wg-BG-2.conf" 203.0.113.21:51820     # same server as BG-1
    conf "$WGS_DL/wg-BG-3.conf" 203.0.113.22:51820
    conf "$WGS_DL/wg-NL-1.conf" 203.0.113.23:51820
    for n in wg-BG-1 wg-BG-2 wg-BG-3 wg-NL-1; do ctl import "$n.conf" >/dev/null; done
    ctl set autoswitch 1 >/dev/null
    date +%s > "$STATE/fake_hs"
    ctl up wg-BG-1 >/dev/null
    check "up" up "$(st state)"
    echo $(( $(date +%s) - 300 )) > "$STATE/fake_hs"     # last handshake 5 min ago
    tick_until recover "restart 1/2" 3; check "restart 1" "restart 1/2" "$(st recover)"
    tick_until recover "restart 2/2" 4; check "restart 2" "restart 2/2" "$(st recover)"
    tick_until recover "switch wg-BG-3" 4; check "switch to the same country, other address" "switch wg-BG-3" "$(st recover)"
    check "settings follow the switch" wg-BG-3 "$(setting ACTIVE)"
    check "kill switch held during recovery" wgs0 "$(route_of)"
    date +%s > "$STATE/fake_hs"
    tick_until state up 3; check "up on the new tunnel" up "$(st state)"
    check "recovery finished" "" "$(st recover)"
    check "switch notified" 1 "$(grep -c 'notification: wg-BG-1 does not answer.*Switched to wg-BG-3' "$WGS_DATA/logs/wg-shield.log")"
    echo "heal: nothing helps - back to the picked tunnel, one notification"
    ctl up wg-NL-1 >/dev/null
    echo $(( $(date +%s) - 300 )) > "$STATE/fake_hs"
    tick_until recover failed 14; check "recovery gave up" failed "$(st recover)"
    check "back on the picked tunnel" wg-NL-1 "$(setting ACTIVE)"
    check "state down" down "$(st state)"
    check "kill switch keeps traffic in the dead tunnel" wgs0 "$(route_of)"
    check "failure notified once" 1 "$(grep -c 'notification: wg-NL-1 does not answer' "$WGS_DATA/logs/wg-shield.log")"
fi

if want pause; then
    echo "pause: direct for a while, resume"
    reset_state
    conf "$WGS_DL/wg-DE-2.conf" 203.0.113.31:51820
    ctl import wg-DE-2.conf >/dev/null
    date +%s > "$STATE/fake_hs"
    ctl up wg-DE-2 >/dev/null
    ctl pause 5 >/dev/null
    check "paused" paused "$(st state)"
    check "paused = direct" wlan0 "$(route_of)"
    ctl resume >/dev/null
    check "resumed" up "$(st state)"
    check "resumed = tunnel" wgs0 "$(route_of)"
    ctl remove wg-DE-2 >/dev/null
    check "removing the active tunnel turns it off" off "$(st state)"
    check "off = direct" wlan0 "$(route_of)"
fi

if want networks; then
    echo "networks: loss of the default network, a second network"
    reset_state
    conf "$WGS_DL/wg-FR-1.conf" 203.0.113.41:51820
    ctl import wg-FR-1.conf >/dev/null
    date +%s > "$STATE/fake_hs"
    ctl up wg-FR-1 >/dev/null
    ip rule del pref 31000; ip rule del pref 16000
    ctl status >/dev/null
    check "no network: still captured (not direct)" wgs0 "$(route_of)"
    check "no network: no wlan0 rules left" 0 "$(ip rule | grep -c 'lookup 1028')"
    ip rule add pref 16000 fwmark 0x10064/0x1ffff iif lo lookup 1028
    ip rule add pref 31000 fwmark 0x0/0xffff iif lo lookup 1028
    ctl status >/dev/null
    check "network back: tunnel" wgs0 "$(route_of)"
    # mobile data next to Wi-Fi: netId 101, table 1029
    ip link add rmnet0 type veth peer name rmnet0p && ip link set rmnet0p up && ip link set rmnet0 up
    ip addr add 10.64.0.2/24 dev rmnet0
    ip route add 10.64.0.0/24 dev rmnet0 table 1029
    ip route add default via 10.64.0.1 dev rmnet0 table 1029
    echo "1029 rmnet0" >> "$WGS_RT_TABLES"
    echo "101 INTERNET&NOT_RESTRICTED&TRUSTED&VALIDATED" >> "$RUN/networks"
    ip rule add pref 16000 fwmark 0x10065/0x1ffff iif lo lookup 1029
    ctl status >/dev/null
    dev_of() { ip route get 1.1.1.1 mark "$1" ${2:+uid $2} 2>&1 | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n1; }
    check "socket bound to mobile data -> tunnel" wgs0 "$(dev_of 0x10065)"
    if [ "${WGS_UIDS:-}" = 1 ]; then
        check "Android's check on mobile data stays on it" rmnet0 "$(dev_of 0x10065 1073)"
        check "captive portal app stays on Wi-Fi" wlan0 "$(dev_of 0x10064 10050)"
    else
        echo "  skip uid exemptions (no subuid range: unshare --map-auto failed)"
    fi
    check "status lists it" 1 "$(st nets | grep -c '1029/tunnel')"
    [ "$(st nets | grep -c '1029/tunnel')" = 1 ] || echo "    nets=$(st nets)"
    # an IMS-like restricted network (permission bits 18-19 = SYSTEM): left alone
    ip rule add pref 16000 fwmark 0xd0066/0xdffff iif lo lookup 1029
    ctl status >/dev/null
    check "restricted carrier network not captured" rmnet0 "$(dev_of 0xd0066)"
    ip rule del pref 16000 fwmark 0xd0066/0xdffff iif lo lookup 1029
    ip rule del pref 16000 fwmark 0x10065/0x1ffff iif lo lookup 1029
    ctl status >/dev/null
    check "its rules go with it" 0 "$(ip rule | grep -c 'fwmark 0x65/0xffff')"
    sed -i '/^101 /d' "$RUN/networks"
fi

if want watchdog; then
    echo "watchdog: service.sh, ip monitor fast capture, restart"
    reset_state
    conf "$WGS_DL/wg-IT-1.conf" 203.0.113.51:51820
    ctl import wg-IT-1.conf >/dev/null
    date +%s > "$STATE/fake_hs"
    ctl up wg-IT-1 >/dev/null
    WGS_FAST=1000 $TSH "$MOD/service.sh" </dev/null >/dev/null 2>&1 &
    _n=0; while [ ! -s "$STATE/monitor.pid" ] && [ "$_n" -lt 50 ]; do sleep 0.1; _n=$((_n + 1)); done
    sleep 0.5
    wd=$(cat "$STATE/watchdog.pid" 2>/dev/null)
    check "watchdog running" yes "$(kill -0 "$wd" 2>/dev/null && echo yes || echo no)"
    check "network watch running" yes "$(p=$(cat "$STATE/monitor.pid" 2>/dev/null); [ -n "$p" ] && kill -0 "$p" 2>/dev/null && echo yes || echo no)"
    echo "102 INTERNET&NOT_RESTRICTED&TRUSTED" >> "$RUN/networks"
    ip rule add pref 16000 fwmark 0x10066/0x1ffff iif lo lookup 1028
    _n=0; while ! ip rule | grep -q '^5022:.*fwmark 0x66/0xffff'; do [ "$_n" -ge 30 ] && break; sleep 0.1; _n=$((_n + 1)); done
    check "new network captured within 3 s" yes "$(ip rule | grep -q '^5022:.*fwmark 0x66/0xffff' && echo yes || echo no)"
    out=$(ctl restart)
    check "restart" 1 "$(echo "$out" | kv restarted)"
    wd2=$(cat "$STATE/watchdog.pid" 2>/dev/null)
    check "old watchdog gone" no "$(kill -0 "$wd" 2>/dev/null && echo yes || echo no)"
    check "new watchdog running" yes "$( [ "$wd2" != "$wd" ] && kill -0 "$wd2" 2>/dev/null && echo yes || echo no)"
    kill "$wd2" 2>/dev/null; sleep 0.5
    p=$(cat "$STATE/monitor.pid" 2>/dev/null); [ -n "$p" ] && kill "$p" 2>/dev/null
    ip rule del pref 16000 fwmark 0x10066/0x1ffff iif lo lookup 1028
    sed -i '/^102 /d' "$RUN/networks"
fi

if want dns; then
    echo "dns: app DNS goes to the tunnel's DNS while it captures traffic"
    nat() { cat "$WGS_IPT_DIR/nat" 2>/dev/null; }
    hasnat() { nat | grep -qxF -- "$1" && echo yes || echo no; }
    J="-A OUTPUT -j wgs_dns"; DN="-A wgs_dns -o wgs0 -p udp --dport 53 -j DNAT --to-destination 10.2.0.1:53"
    reset_state; rm -rf "$WGS_IPT_DIR"
    conf "$WGS_DL/wg-DE-1.conf" 203.0.113.61:51820
    ctl import wg-DE-1.conf >/dev/null
    date +%s > "$STATE/fake_hs"
    ctl up wg-DE-1 >/dev/null
    check "OUTPUT jumps to wgs_dns" yes "$(hasnat "$J")"
    check "udp 53 DNAT to the tunnel DNS" yes "$(hasnat "$DN")"
    check "tcp 53 DNAT to the tunnel DNS" yes "$(hasnat "-A wgs_dns -o wgs0 -p tcp --dport 53 -j DNAT --to-destination 10.2.0.1:53")"
    check "Android's network check left alone" yes "$(hasnat "-A wgs_dns -m owner --uid-owner 1073 -j RETURN")"
    check "captive portal login left alone" yes "$(hasnat "-A wgs_dns -m owner --uid-owner 10050 -j RETURN")"
    check "endpoint lookup resolver left alone" yes "$(hasnat "-A wgs_dns -d 9.9.9.9 -j RETURN")"
    check "logged" 1 "$(grep -c "apps use the tunnel's DNS 10.2.0.1" "$WGS_DATA/logs/wg-shield.log")"
    "$WGS_IPT" -w -t nat -D OUTPUT -j wgs_dns
    ctl status >/dev/null
    check "jump removed by someone else: repaired" yes "$(hasnat "$J")"
    mkdir -p "$WGS_MODULES/dnscrypt-proxy-android"
    ctl status >/dev/null
    check "DNSCrypt Proxy on: no redirect" no "$(hasnat "$J")"
    check "DNSCrypt Proxy on: chain removed" no "$(nat | grep -qx -- '-N wgs_dns' && echo yes || echo no)"
    touch "$WGS_MODULES/dnscrypt-proxy-android/disable"
    ctl status >/dev/null
    check "DNSCrypt Proxy disabled: redirect back" yes "$(hasnat "$DN")"
    rm -rf "$WGS_MODULES/dnscrypt-proxy-android"
    ctl set killswitch 0 >/dev/null
    echo $(( $(date +%s) - 600 )) > "$STATE/fake_hs"
    ctl status >/dev/null
    check "tunnel down, kill switch off: network DNS again" no "$(hasnat "$J")"
    date +%s > "$STATE/fake_hs"; ctl set killswitch 1 >/dev/null; ctl status >/dev/null
    check "up again: redirect back" yes "$(hasnat "$J")"
    ctl down >/dev/null
    check "down: redirect removed" no "$(hasnat "$J")"
    check "down: chain removed" no "$(nat | grep -qx -- '-N wgs_dns' && echo yes || echo no)"
    sed -i 's#^DNS = .*#DNS = fd00::53, 10.2.0.9, example.lan#' "$WGS_DL/wg-DE-1.conf"
    ctl import wg-DE-1.conf >/dev/null; ctl up wg-DE-1 >/dev/null
    check "first IPv4 of the DNS line" yes "$(hasnat "-A wgs_dns -o wgs0 -p udp --dport 53 -j DNAT --to-destination 10.2.0.9:53")"
    ctl down >/dev/null
    sed -i '/^DNS = /d' "$WGS_DL/wg-DE-1.conf"
    ctl import wg-DE-1.conf >/dev/null; ctl up wg-DE-1 >/dev/null
    check "no DNS line: DNS left alone" no "$(hasnat "$J")"
    ctl down >/dev/null
    conf "$WGS_DL/wg-DE-1.conf" 203.0.113.61:51820
    ctl import wg-DE-1.conf >/dev/null
    WGS_IPT="$RUN/no-iptables" ctl up wg-DE-1 >/dev/null
    WGS_IPT="$RUN/no-iptables" ctl status >/dev/null; WGS_IPT="$RUN/no-iptables" ctl status >/dev/null
    check "no iptables: one warning, no state" "1 no" "$(grep -c "could not send DNS to 10.2.0.1" "$WGS_DATA/logs/wg-shield.log") $([ -f "$STATE/dns.want" ] && echo yes || echo no)"
    check "no iptables: traffic still through the tunnel" wgs0 "$(route_of)"
    ctl down >/dev/null
fi

if want dns_reboot; then
    echo "dns_reboot: after a reboot the DNS redirect is set up as new, not as repaired"
    reset_state; rm -rf "$WGS_IPT_DIR"
    conf "$WGS_DL/wg-DE-4.conf" 203.0.113.63:51820
    ctl import wg-DE-4.conf >/dev/null
    date +%s > "$STATE/fake_hs"
    ctl up wg-DE-4 >/dev/null
    check "redirect on before the reboot" 1 "$(grep -c "apps use the tunnel's DNS 10.2.0.1" "$WGS_DATA/logs/wg-shield.log")"
    rm -rf "$WGS_IPT_DIR"                 # a reboot empties iptables
    $TSH "$MOD/post-fs-data.sh" >/dev/null 2>&1
    ctl status >/dev/null
    check "after the reboot: no 'removed by someone else' warning" 0 "$(grep -c 'DNS: the redirect was removed by someone else' "$WGS_DATA/logs/wg-shield.log")"
    check "after the reboot: set up again" 2 "$(grep -c "apps use the tunnel's DNS 10.2.0.1" "$WGS_DATA/logs/wg-shield.log")"
    ctl down >/dev/null
fi

if want dns_route; then
    echo "dns_route: only DNS the routing sends into the tunnel is redirected (real iptables)"
    IPTR=$(command -v iptables 2>/dev/null)
    if [ -z "$IPTR" ] || ! command -v python3 >/dev/null || ! "$IPTR" -w -t nat -L -n >/dev/null 2>&1 || ! "$IPTR" -w -t mangle -L -n >/dev/null 2>&1; then
        echo "  skip (no usable iptables nat/mangle or python3 in the namespace)"
    else
        reset_state
        # an IMS-like carrier network (permission SYSTEM): stays outside the tunnel
        ip link add rmnet1 type veth peer name rmnet1p && ip link set rmnet1p up && ip link set rmnet1 up
        ip addr add 10.65.0.2/24 dev rmnet1
        ip route add 10.65.0.0/24 dev rmnet1 table 1030
        ip route add default via 10.65.0.1 dev rmnet1 table 1030
        echo "1030 rmnet1" >> "$WGS_RT_TABLES"
        ip rule add pref 16000 fwmark 0xd0066/0xdffff iif lo lookup 1030
        conf "$WGS_DL/wg-DE-3.conf" 203.0.113.62:51820
        ctl import wg-DE-3.conf >/dev/null
        date +%s > "$STATE/fake_hs"
        WGS_IPT=$IPTR ctl up wg-DE-3 >/dev/null
        # where one UDP query (socket mark as DnsResolver sets it) leaves:
        # "<out interface> <source> <destination>" from counting rules
        dns_leaves() {  # dns_leaves MARK SERVER
            "$IPTR" -w -t mangle -F POSTROUTING
            for o in wlan0 wgs0 rmnet1; do for s in 192.168.1.50 10.2.0.2 10.65.0.2; do for d in "$2" 10.2.0.1; do
                "$IPTR" -w -t mangle -A POSTROUTING -o "$o" -s "$s" -d "$d" -p udp --dport 53 -j ACCEPT
            done; done; done
            python3 -I -c 'import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, getattr(socket, "SO_MARK", 36), int(sys.argv[1], 16))
try:
    s.connect((sys.argv[2], 53)); s.send(b"q")
except OSError:
    pass' "$1" "$2"
            "$IPTR" -w -t mangle -L POSTROUTING -v -n -x | awk '$1 ~ /^[0-9]+$/ && $1 > 0 { print $7, $8, $9; exit }'
            "$IPTR" -w -t mangle -F POSTROUTING
        }
        check "Wi-Fi LAN resolver: stays on the LAN" "wlan0 192.168.1.50 192.168.1.1" "$(dns_leaves 0x10064 192.168.1.1)"
        check "resolver reached through the tunnel: tunnel DNS" "wgs0 10.2.0.2 10.2.0.1" "$(dns_leaves 0x10064 198.51.100.53)"
        check "carrier service network: its own resolver" "rmnet1 10.65.0.2 10.65.0.53" "$(dns_leaves 0xd0066 10.65.0.53)"
        WGS_IPT=$IPTR ctl down >/dev/null
        check "down: real nat table clean" 0 "$("$IPTR" -w -t nat -S 2>/dev/null | grep -c wgs_dns)"
        ip rule del pref 16000 fwmark 0xd0066/0xdffff iif lo lookup 1030
        ip link del rmnet1 2>/dev/null
        sed -i '/^1030 /d' "$WGS_RT_TABLES"
    fi
fi

if want busybox_path; then
    echo "busybox_path: KernelSU, APatch and Magisk busybox are found"
    bbof() { env -u WGS_BB $TSH -c '. "$WGS_MODDIR/sh/common.sh"; echo "$BB"'; }
    rm -rf "$WGS_ADB/ksu" "$WGS_ADB/ap" "$WGS_ADB/magisk"
    mkdir -p "$WGS_ADB/magisk"; printf '#!/bin/sh\n' > "$WGS_ADB/magisk/busybox"; chmod 755 "$WGS_ADB/magisk/busybox"
    check "Magisk only" "$WGS_ADB/magisk/busybox" "$(bbof)"
    mkdir -p "$WGS_ADB/ap/bin"; cp "$WGS_ADB/magisk/busybox" "$WGS_ADB/ap/bin/busybox"
    check "APatch before Magisk" "$WGS_ADB/ap/bin/busybox" "$(bbof)"
    mkdir -p "$WGS_ADB/ksu/bin"; cp "$WGS_ADB/magisk/busybox" "$WGS_ADB/ksu/bin/busybox"
    check "KernelSU first" "$WGS_ADB/ksu/bin/busybox" "$(bbof)"
    rm -rf "$WGS_ADB/ksu" "$WGS_ADB/ap" "$WGS_ADB/magisk"
    check "none: the KernelSU path (as before)" "$WGS_ADB/ksu/bin/busybox" "$(bbof)"
fi

echo
echo "passed $PASS, failed $FAILN"
[ "$FAILN" = 0 ]
