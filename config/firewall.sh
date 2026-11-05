# /etc/runit/core-services/85-firewall.sh: runs before any network comes up.
# This is not the nftables service on purpose: stopping that one flushes the rules.
# A broken /etc/nftables.conf must not leave the machine open, so the default
# rules are built in here too.
msg "Loading firewall..."
if ! nft -f /etc/nftables.conf; then
	msg_warn "/etc/nftables.conf did not load, using the built-in rules"
	nft -f - <<'RULES' || msg_error "NO FIREWALL: nft could not load any rules"
destroy table inet kombain
table inet kombain {
  chain input {
    type filter hook input priority 0; policy drop;
    ct state vmap { established : accept, related : accept, invalid : drop }
    iif lo accept
    icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert, nd-router-advert } accept
    udp sport 67 udp dport 68 accept
    udp sport 547 udp dport 546 accept
  }
  chain forward {
    type filter hook forward priority 0; policy drop;
  }
}
RULES
fi
