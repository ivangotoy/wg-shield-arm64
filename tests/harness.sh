#!/usr/bin/env bash
# WG Shield Arm64 - offline test harness (Linux PC, no phone, no root).
#
# Runs the module's own scripts inside a private user + network namespace
# (unshare -rn: uid 0 and CAP_NET_ADMIN there, nothing outside is touched).
# netd is imitated with its rules (16000 explicit network, 31000 default
# network) and a table per network; the tunnel link is a veth
# (WGS_LINKTYPE), the handshake comes from $STATE/fake_hs. Android tools
# (getprop, dumpsys, pm, ping, su, cmd) are small fakes.
#
#   bash tests/harness.sh            run every case
#   bash tests/harness.sh -k NAME    run the cases whose name contains NAME
#   WGS_TEST_BB=/path/busybox bash tests/harness.sh   the same with busybox ash
#
# Scratch goes to tests/.run (ext4 next to the repo), removed at the start.
set -u
REPO=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
if [ "${WGS_IN_NS:-}" != 1 ]; then
    command -v unshare >/dev/null || { echo "unshare (util-linux) is needed"; exit 2; }
    command -v ip >/dev/null || { echo "ip (iproute2) is needed"; exit 2; }
    exec env WGS_IN_NS=1 unshare -rn bash "$0" "$@"
fi
FILTER=""; [ "${1:-}" = -k ] && FILTER=${2:-}
# WGS_TEST_BB=/path/to/busybox: run the scripts with busybox ash and its
# applets (unzip, gzip, ...) like KernelSU does; default: bash + host tools
TSH=$(command -v bash)
[ -n "${WGS_TEST_BB:-}" ] && TSH="$WGS_TEST_BB sh"

RUN="$REPO/tests/.run"
rm -rf "$RUN"; mkdir -p "$RUN"
FAKES="$RUN/fakes"; mkdir -p "$FAKES"

# ---- fakes ---------------------------------------------------------------------
cat > "$FAKES/getprop" <<'EOF'
#!/bin/sh
case "$1" in sys.boot_completed) echo 1 ;; debug.tracing.screen_state) echo 2 ;; esac
EOF
cat > "$FAKES/dumpsys" <<'EOF'
#!/bin/sh
[ "$1" = connectivity ] && echo "  NetworkAgentInfo{network{100}  handle{1}  ni{WIFI CONNECTED} Capabilities: INTERNET&NOT_RESTRICTED&TRUSTED&VALIDATED}"
exit 0
EOF
printf '#!/bin/sh\necho "package:com.android.captiveportallogin uid:10050"\n' > "$FAKES/pm"
printf '#!/bin/sh\nexit 1\n' > "$FAKES/ping"
printf '#!/bin/sh\nexit 0\n' > "$FAKES/su"
printf '#!/bin/sh\nexit 0\n' > "$FAKES/cmd"
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
export WGS_SH="$TSH"
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

echo
echo "passed $PASS, failed $FAILN"
[ "$FAILN" = 0 ]
