#!/bin/sh
# wg-watch - userspace/kernel-agnostic WireGuard backend supervisor for wg-portal.
#
# wg-portal (control plane) writes wg-quick-format "<ifname>.conf" files into
# /etc/wireguard (shared volume). This script (data plane, host network) watches
# that directory and keeps the corresponding tunnel(s) alive:
#
#   * kernel module present  -> wg-quick uses it (ip link add type wireguard)
#   * kernel module absent   -> wg-quick's fallback auto-launches userspace
#     wireguard-go (Debian/Ubuntu package; add 'wireguard' on Alpine).
#
# Fixes vs a bare `exec wg-quick` entrypoint (all seen in production, e.g. on a
# Synology DSM kernel 4.4 without the module):
#   1. (re)apply always happens from a clean slate: stale host devices and
#      leftover control sockets (they survive container restarts because /run
#      is container-ephemeral but wg-quick does NOT wait for a fresh socket)
#      are removed first, so `wg setconf` can never race a mute daemon.
#   2. after applying, the config is VERIFIED: `wg show` must report the
#      configured ListenPort with the expected peers. A daemon that only bound
#      an ephemeral port ("mute" - clients never reach it) is detected and
#      retried instead of being declared success.
#   3. the loop keeps running: md5-watched configs are re-applied when
#      wg-portal rewrites them, and a live-but-broken tunnel self-heals.
#
# Optional NAT self-healing (for "borrow route via this machine" topologies):
#   NAT_CIDR  e.g. 10.13.13.0/24  (your tunnel client subnet)
#   NAT_IFACE e.g. eth0           (machine's LAN egress interface)
# Both empty (default) disables it. iptables state is lost on host reboot, so
# the watchdog re-establishes the MASQUERADE/FORWARD rules at startup; rules
# added by the host package manager (Docker's DOCKER chain) are never touched.
#
set -u

CONF_DIR="${CONF_DIR:-/etc/wireguard}"
STATE_DIR="${STATE_DIR:-/tmp/wg-backend-state}"
INTERVAL="${INTERVAL:-5}"
NAT_CIDR="${NAT_CIDR:-}"
NAT_IFACE="${NAT_IFACE:-}"
NAT_CHAIN="WGPORTAL_NAT"

have() { command -v "$1" >/dev/null 2>&1; }

log() { echo "[wg-watch $(date '+%Y-%m-%d %H:%M:%S')] $*"; }

nat_mode="off"
[ -n "$NAT_CIDR" ] && [ -n "$NAT_IFACE" ] && nat_mode="on ($NAT_CIDR -> $NAT_IFACE, chain $NAT_CHAIN)"

log "wireguard-go:  $(have wireguard-go && command -v wireguard-go || echo 'NOT INSTALLED (userspace fallback unavailable)')"
log "wireguard-quick: $(have wg-quick && command -v wg-quick || echo 'NOT INSTALLED (required)')"
log "kernel module:   $(ip link add dev __wg_probe__ type wireguard 2>/dev/null && { ip link del dev __wg_probe__; echo 'AVAILABLE (kernel mode)'; } || echo 'NOT AVAILABLE (userspace fallback will be used)')"
log "config dir:      $CONF_DIR (shared with wg-portal)"
log "nat self-heal:   $nat_mode"

[ -n "$NAT_IFACE" ] && [ -n "$NAT_CIDR" ] || true
if ! have wg-quick; then log "FATAL: wg-quick not found"; exit 1; fi
mkdir -p "$STATE_DIR"

# ---------------------------------------------------------------- NAT setup --
ensure_nat() {
    [ "$nat_mode" = "off" ] && return 0
    have iptables || { log "warn: iptables not installed, skipping NAT"; return 0; }
    ip link show "$NAT_IFACE" >/dev/null 2>&1 || { log "warn: interface $NAT_IFACE not up yet"; return 1; }
    sysctl -q -w net.ipv4.ip_forward=1
    # dedicated user chain so our rules coexist with the host's (e.g. Docker's)
    if ! iptables -t nat -n | grep -q "^Chain $NAT_CHAIN"; then
        iptables -t nat -N "$NAT_CHAIN" 2>/dev/null
        iptables -t nat -C POSTROUTING -j "$NAT_CHAIN" 2>/dev/null || iptables -t nat -A POSTROUTING -j "$NAT_CHAIN"
    fi
    iptables -t nat -C "$NAT_CHAIN" -s "$NAT_CIDR" -o "$NAT_IFACE" -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A "$NAT_CHAIN" -s "$NAT_CIDR" -o "$NAT_IFACE" -j MASQUERADE
    iptables -C FORWARD -s "$NAT_CIDR" -j ACCEPT 2>/dev/null || iptables -I FORWARD -s "$NAT_CIDR" -j ACCEPT
    log "nat: MASQUERADE $NAT_CIDR -> $NAT_IFACE ensured (chain $NAT_CHAIN)"
}

# -------------------------------------------------------------- clean slate --
# Remove everything a previous daemon may have left in the host network
# namespace: device, wireguard-go process, stale control socket.
clean_slate() {
    ifname="$1"
    # userspace daemon first, so it releases the TUN fd before link delete
    pkill -f "wireguard-go $ifname" 2>/dev/null
    pkill -f "wireguard-go .* $ifname" 2>/dev/null
    sleep 1
    ip link del dev "$ifname" 2>/dev/null
    # stale unix control socket from a previous container generation
    rm -f "/run/wireguard/$ifname.sock" 2>/dev/null
}

# --------------------------------------------------------- start/verify iface --
# wg-quick starts the (kernel or userspace) daemon detached; we then poll the
# control socket until a daemon answers, and VERIFY the reported ListenPort
# matches the configured one - the signature of a correctly configured daemon.
start_iface() {
    ifname="$1"
    conf="$CONF_DIR/$ifname.conf"

    [ -f "$conf" ] || { log "$ifname: no config file, skipping"; return 0; }

    # kernel-mode-only directives; userspace `wg setconf` rejects them.
    # (tolerate "Key = value" spacing, as written by recent wg-portal)
    rawconf="$STATE_DIR/$ifname.raw.conf"
    sed -e '/^[[:space:]]*Address[[:space:]]*=/d' -e '/^[[:space:]]*SaveConfig[[:space:]]*=/d' \
        -e '/^[[:space:]]*MTU[[:space:]]*=/d' \
        -e '/^[[:space:]]*PreUp[[:space:]]*=/d' -e '/^[[:space:]]*PostUp[[:space:]]*=/d' \
        -e '/^[[:space:]]*PreDown[[:space:]]*=/d' -e '/^[[:space:]]*PostDown[[:space:]]*=/d' \
        -e 's/^[[:space:]]*#.*$//' "$conf" > "$rawconf"

    wantport=$(sed -n 's/^[[:space:]]*ListenPort[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$conf" | head -1)
    [ -n "$wantport" ] || wantport=51820

    clean_slate "$ifname"

    if ! wg-quick up "$ifname" 2>"$STATE_DIR/$ifname.err" \
       && ! wg-quick down "$ifname" 2>/dev/null; then
        log "$ifname: initial wg-quick apply failed: $(tail -n 2 "$STATE_DIR/$ifname.err" 2>/dev/null | tr '\n' ' ')"
    fi
    # userspace fallback: daemon is spawned detached by wg-quick and binds its
    # control socket right after wg-quick returns; if the file is missing the
    # daemon is still coming (or the module-less path needs a re-apply).
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ -S "/run/wireguard/$ifname.sock" ] && break
        wg setconf "$ifname" "$rawconf" 2>/dev/null || true
        sleep 1
    done
    if [ ! -S "/run/wireguard/$ifname.sock" ]; then
        log "$ifname: no control socket after retries (daemon not running)"
        return 1
    fi
    # VERIFY: a "mute" daemon answers on an ephemeral port with zero peers.
    reported=$(wg show "$ifname" 2>/dev/null | grep 'listening port' | awk '{print $3}')
    [ "$reported" = "$wantport" ] || { log "$ifname: REAPPLY (daemon on port ${reported:-none}, want $wantport)"; wg setconf "$ifname" "$rawconf"; sleep 1; reported=$(wg show "$ifname" 2>/dev/null | grep 'listening port' | awk '{print $3}'); [ "$reported" = "$wantport" ] || { log "$ifname: daemon still on wrong port, next cycle"; return 1; }; }
    peers=$(wg show "$ifname" peers 2>/dev/null | grep -c 'public key' || true)
    log "$ifname: UP and verified (listening port $reported, $peers peer(s))"
    return 0
}

# ------------------------------------------------------------- main loop ------
ensure_nat || true
log "watching $CONF_DIR every ${INTERVAL}s (state in $STATE_DIR)"

prev_md5s=""
while :; do
    # NAT state can be flushed by host reboots/packages: re-ensure every 60s
    every=$(( (SECONDS / 60) + 1 ))
    [ $every -eq 1 ] && ensure_nat || true

    for conf in "$CONF_DIR"/*.conf; do
        [ -e "$conf" ] || continue
        ifname=$(basename "$conf" .conf)
        md5=$(md5sum "$conf" 2>/dev/null | awk '{print $1}')
        case " $prev_md5s " in
            *" $ifname:$md5 "*) : ;;  # unchanged
            *)
                log "$ifname: config change detected (md5 $md5)"
                start_iface "$ifname"
                ;;
        esac
        prev_md5s="$prev_md5s $ifname:$md5"
    done

    # remove state for deleted configs
    for state in "$STATE_DIR"/*.raw.conf; do
        [ -e "$state" ] || continue
        ifname=$(basename "$state" .raw.conf)
        [ -e "$CONF_DIR/$ifname.conf" ] || {
            log "$ifname: config removed, tearing down"
            clean_slate "$ifname"
            prev_md5s=$(echo " $prev_md5s " | sed "s/ $ifname:[^ ]* //")
            rm -f "$state"
        }
    done

    sleep "$INTERVAL"
done
