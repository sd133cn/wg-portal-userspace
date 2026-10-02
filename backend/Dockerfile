# WireGuard tunnel backend: applies wg-quick-format configs that wg-portal writes
# into /etc/wireguard, using the kernel module when available and automatically
# falling back to userspace wireguard-go on kernels without the module
# (e.g. Synology DSM 4.4 kernels).
#
# The entrypoint (wg-watch.sh) is a small supervisor: it (re)applies any
# changed config, keeps the daemon alive, verifies it is actually configured
# (guards against a "mute" daemon listening on a random port), and can self-heal
# the NAT/masquerade rules when enabled via NAT_CIDR + NAT_IFACE.
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        wireguard-go \
        wireguard-tools \
        iptables \
        iproute2 \
        procps \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY wg-watch.sh /usr/local/bin/wg-watch.sh
RUN chmod +x /usr/local/bin/wg-watch.sh

# Shared with wg-portal: portal writes <ifname>.conf here, backend applies it.
VOLUME ["/etc/wireguard"]

ENTRYPOINT ["/usr/local/bin/wg-watch.sh"]
