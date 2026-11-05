#!/usr/bin/env python3
"""Network probes for tests/firewall.sh. Prints OPEN, dropped or refused."""
import socket
import struct
import sys


def family(host):
    return socket.AF_INET6 if ":" in host else socket.AF_INET


def serve_tcp(host, port):
    s = socket.socket(family(host))
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if ":" in host:
        s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
    s.bind((host, int(port)))
    s.listen(8)
    while True:
        c, _ = s.accept()
        c.sendall(b"ok")
        c.close()


def serve_udp(host, port):
    s = socket.socket(family(host), socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((host, int(port)))
    while True:
        _, addr = s.recvfrom(64)
        s.sendto(b"ok", addr)


def tcp(host, port):
    s = socket.socket(family(host))
    s.settimeout(1.2)
    try:
        s.connect((host, int(port)))
        print("OPEN" if s.recv(2) == b"ok" else "unexpected")
    except socket.timeout:
        print("dropped")
    except OSError as e:
        print("refused" if "refused" in str(e) else f"error: {e}")


def udp(host, port, source_port=None):
    s = socket.socket(family(host), socket.SOCK_DGRAM)
    s.settimeout(1.2)
    if source_port:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("", int(source_port)))
    try:
        s.sendto(b"x", (host, int(port)))
        s.recvfrom(64)
        print("OPEN")
    except socket.timeout:
        print("dropped")
    except OSError as e:
        print("refused" if "refused" in str(e) else f"error: {e}")


def router_advert(ifname):
    """Sends one IPv6 router advertisement to all nodes on the link."""
    s = socket.socket(socket.AF_INET6, socket.SOCK_RAW, socket.IPPROTO_ICMPV6)
    s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_HOPS, 255)
    s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_IF, socket.if_nametoindex(ifname))
    # type 134, code 0, checksum filled in by the kernel, hop limit 64, no flags,
    # router lifetime 1800 s, reachable and retransmit timers unset
    packet = struct.pack("!BBHBBHII", 134, 0, 0, 64, 0, 1800, 0, 0)
    s.sendto(packet, ("ff02::1", 0, 0, socket.if_nametoindex(ifname)))


if __name__ == "__main__":
    {"serve-tcp": serve_tcp, "serve-udp": serve_udp, "tcp": tcp, "udp": udp,
     "router-advert": router_advert}[sys.argv[1]](*sys.argv[2:])
