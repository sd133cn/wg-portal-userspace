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
#   NAT_CIDR  e.g. 10.11.12.0/24  (your tunnel client subnet)
#   NAT_IFACE e.g. eth0           (machine's LAN egress interface)
# Both empty (default) disables it. iptables state is lost on host reboot, so
# the watchdog re-establishes the MASQUERADE/FORWARD rules at startup; rules
# added by the host package manager (Docker's DOCKER chain) are never touched.
# The iptables binary is PROBED, not assumed: Debian ships `iptables` as the
# nf_tables build, which is unusable on kernels without nftables support
# (rc=4 "table does not exist", seen on Synology DSM 4.4) — those boxes need
# `iptables-legacy`. Without the probe NAT silently disappears.
# Rule existence is also checked defensively (see rule_present): some DSM builds
# answer "Bad rule (does a matching rule exist in that chain?)" for `-C` on
# BUILT-IN chains even when the rule is there, which would append a duplicate
# rule on every cycle - so the rule listing is used as a fallback.
# Forwarding (net.ipv4.ip_forward=1) must be enabled on the host: a container
# normally cannot write /proc/sys, so the watchdog only warns when it is off.
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

# Pick a WORKING iptables binary (cached in $IPT after the first call).
IPT=""
pick_iptables() {
    [ -n "$IPT" ] && return 0
    for cand in iptables iptables-legacy; do
        if have "$cand" && "$cand" -L -n >/dev/null 2>&1; then IPT="$cand"; return 0; fi
    done
    return 1
}

nat_mode="off"
[ -n "$NAT_CIDR" ] && [ -n "$NAT_IFACE" ] && nat_mode="on ($NAT_CIDR -> $NAT_IFACE, chain $NAT_CHAIN)"

log "wireguard-go:  $(have wireguard-go && command -v wireguard-go || echo 'NOT INSTALLED (userspace fallback unavailable)')"
log "wireguard-quick: $(have wg-quick && command -v wg-quick || echo 'NOT INSTALLED (required)')"
log "kernel module:   $(ip link add dev __wg_probe__ type wireguard 2>/dev/null && { ip link del dev __wg_probe__; echo 'AVAILABLE (kernel mode)'; } || echo 'NOT AVAILABLE (userspace fallback will be used)')"
log "config dir:      $CONF_DIR (shared with wg-portal)"
log "nat self-heal:   $nat_mode"
pick_iptables && log "iptables:        $IPT ($($IPT --version 2>&1 | head -1))" \
    || log "iptables:        NONE USABLE (nf_tables and legacy both fail; NAT unavailable)"
if ! have wg-quick; then log "FATAL: wg-quick not found"; exit 1; fi
mkdir -p "$STATE_DIR"

# ---------------------------------------------------------------- NAT setup --
# Is this exact rule already in <table>/<chain>? `-C` is the fast path, but some
# patched kernels/iptables builds answer "Bad rule (does a matching rule exist
# in that chain?)" for built-in chains even when the rule IS there (seen on
# Synology DSM's own iptables 1.8.3) - blindly trusting that would append a
# duplicate rule on every cycle. So fall back to grepping the rule listing.
rule_present() {
    t="$1"; c="$2"; shift 2
    "$IPT" -t "$t" -C "$c" "$@" >/dev/null 2>&1 && return 0
    "$IPT" -t "$t" -S "$c" 2>/dev/null | grep -qF -- "-A $c $*" && return 0
    "$IPT" -t "$t" -S 2>/dev/null | grep -qF -- "-A $c $*"
}

ensure_nat() {
    [ "$nat_mode" = "off" ] && return 0
    pick_iptables || { log "warn: no usable iptables binary, skipping NAT"; return 0; }
    ip link show "$NAT_IFACE" >/dev/null 2>&1 || { log "warn: interface $NAT_IFACE not up yet"; return 1; }
    # NAT needs forwarding on the HOST. Inside a plain (non-privileged) container
    # /proc/sys is usually read-only, so this is best-effort: only complain when
    # forwarding is really off and could not be enabled from here.
    if [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" != "1" ]; then
        if [ -w /proc/sys/net/ipv4/ip_forward ]; then
            echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
        elif have sysctl; then
            sysctl -q -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
        fi
        [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = "1" ] \
            || log "warn: ip_forward is not 1 and cannot be set from here (enable it on the host)"
    fi
    changed=""
    # dedicated user chain so our rules coexist with the host's (e.g. Docker's).
    # The jump is checked separately from the chain: `iptables -F` removes rules
    # but keeps chains, so an existing-but-empty chain must still be re-hooked.
    if ! "$IPT" -t nat -S "$NAT_CHAIN" >/dev/null 2>&1; then
        "$IPT" -t nat -N "$NAT_CHAIN" 2>/dev/null && changed=1
    fi
    rule_present nat POSTROUTING -j "$NAT_CHAIN" \
        || { "$IPT" -t nat -A POSTROUTING -j "$NAT_CHAIN" && changed=1; }
    rule_present nat "$NAT_CHAIN" -s "$NAT_CIDR" -o "$NAT_IFACE" -j MASQUERADE \
        || { "$IPT" -t nat -A "$NAT_CHAIN" -s "$NAT_CIDR" -o "$NAT_IFACE" -j MASQUERADE && changed=1; }
    rule_present filter FORWARD -s "$NAT_CIDR" -j ACCEPT \
        || { "$IPT" -I FORWARD -s "$NAT_CIDR" -j ACCEPT && changed=1; }
    # only talk about it when something actually had to be (re)established -
    # this runs on a timer, so logging unconditionally would flood the log
    [ -n "$changed" ] && log "nat: MASQUERADE $NAT_CIDR -> $NAT_IFACE ensured via $IPT (chain $NAT_CHAIN)"
    return 0
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

    # NOTE: the config PATH is passed to wg-quick (not just the interface name),
    # so CONF_DIR is honoured instead of wg-quick's hardcoded /etc/wireguard.
    if ! wg-quick up "$conf" 2>"$STATE_DIR/$ifname.err" \
       && ! wg-quick down "$conf" 2>/dev/null; then
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
    # NOTE: `wg show <if> peers` prints bare public keys, one per line - grepping
    # for the words "public key" (which only `wg show <if>` prints) yields 0.
    peers=$(wg show "$ifname" peers 2>/dev/null | grep -c . || true)
    wantpeers=$(grep -c '^\[Peer\]' "$conf" 2>/dev/null || true)
    log "$ifname: UP and verified (listening port $reported, $peers peer(s))"
    [ "$peers" = "$wantpeers" ] || log "$ifname: WARN $peers peer(s) active, config declares $wantpeers"
    return 0
}

# ------------------------------------------------------------- main loop ------
ensure_nat || true
log "watching $CONF_DIR every ${INTERVAL}s (state in $STATE_DIR)"

prev_md5s=""
# NAT state can be flushed by host reboots/package upgrades: re-check every 60s.
# Do NOT use $SECONDS for this: on Debian /bin/sh is dash, where SECONDS is not a
# special variable, so the maths silently collapses to "every single cycle".
nat_ticks=$(( 60 / INTERVAL )); [ "$nat_ticks" -lt 1 ] && nat_ticks=1
tick=0
while :; do
    tick=$(( tick + 1 ))
    [ $(( tick % nat_ticks )) -eq 0 ] && ensure_nat || true

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
