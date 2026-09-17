#!/usr/bin/env python3
"""
UDP delay/jitter/loss proxy, for testing multiplayer games without OS-level
network shaping (e.g. containers where `tc netem` isn't available because
the sch_netem kernel module isn't loaded).

It sits between a game client and the real host: the client connects to
this proxy's listen port instead of the host directly, and every packet in
both directions is held for `delay_ms` (+/- `jitter_ms` random variation)
before being forwarded, with an optional random drop chance to simulate
packet loss.

This is a rough approximation, not a kernel-accurate network emulator —
Python/asyncio scheduling itself adds a small amount of jitter on top of
whatever you ask for, and there's no bandwidth/queueing simulation. It's
good enough to answer "does this hold up at roughly 100ms with jitter",
not to get an exact number.

Usage:
    python3 udp_delay_proxy.py --listen-port 8920 --upstream-port 8910 \
        --delay-ms 100 --jitter-ms 20 --loss-pct 0
"""
import argparse
import asyncio
import random


class DownstreamProtocol(asyncio.DatagramProtocol):
    """Faces the client: this is what the client actually connects to."""
    def __init__(self, proxy):
        self.proxy = proxy

    def connection_made(self, transport):
        self.proxy.downstream_transport = transport

    def datagram_received(self, data, addr):
        self.proxy.on_client_packet(data, addr)


class UpstreamProtocol(asyncio.DatagramProtocol):
    """Faces the real host."""
    def __init__(self, proxy):
        self.proxy = proxy

    def connection_made(self, transport):
        self.proxy.upstream_transport = transport

    def datagram_received(self, data, addr):
        self.proxy.on_host_packet(data)


class DelayProxy:
    def __init__(self, delay_ms, jitter_ms, loss_pct, upstream_addr):
        self.delay_ms = delay_ms
        self.jitter_ms = jitter_ms
        self.loss_pct = loss_pct
        self.upstream_addr = upstream_addr
        self.client_addr = None
        self.downstream_transport = None
        self.upstream_transport = None
        self.loop = asyncio.get_event_loop()
        self.forwarded = 0
        self.dropped = 0

    def _delay_seconds(self) -> float:
        d = self.delay_ms + random.uniform(-self.jitter_ms, self.jitter_ms)
        return max(0.0, d) / 1000.0

    def _maybe_drop(self) -> bool:
        if self.loss_pct <= 0:
            return False
        if random.random() < self.loss_pct / 100.0:
            self.dropped += 1
            return True
        return False

    def on_client_packet(self, data: bytes, addr) -> None:
        self.client_addr = addr  # remember where to send host replies back to
        if self._maybe_drop():
            return
        self.forwarded += 1
        self.loop.call_later(self._delay_seconds(), self._send_to_host, data)

    def on_host_packet(self, data: bytes) -> None:
        if self.client_addr is None:
            return
        if self._maybe_drop():
            return
        self.forwarded += 1
        self.loop.call_later(self._delay_seconds(), self._send_to_client, data)

    def _send_to_host(self, data: bytes) -> None:
        if self.upstream_transport:
            self.upstream_transport.sendto(data, self.upstream_addr)

    def _send_to_client(self, data: bytes) -> None:
        if self.downstream_transport and self.client_addr:
            self.downstream_transport.sendto(data, self.client_addr)


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen-port", type=int, required=True, help="port the CLIENT should connect to")
    ap.add_argument("--upstream-host", default="127.0.0.1")
    ap.add_argument("--upstream-port", type=int, required=True, help="the real host's port")
    ap.add_argument("--delay-ms", type=float, default=0.0, help="one-way delay applied in EACH direction")
    ap.add_argument("--jitter-ms", type=float, default=0.0, help="+/- random variation on the delay")
    ap.add_argument("--loss-pct", type=float, default=0.0, help="chance (0-100) to silently drop a packet")
    args = ap.parse_args()

    proxy = DelayProxy(args.delay_ms, args.jitter_ms, args.loss_pct, (args.upstream_host, args.upstream_port))
    loop = asyncio.get_event_loop()

    await loop.create_datagram_endpoint(lambda: DownstreamProtocol(proxy), local_addr=("127.0.0.1", args.listen_port))
    await loop.create_datagram_endpoint(lambda: UpstreamProtocol(proxy), local_addr=("127.0.0.1", 0))

    print(f"[proxy] 127.0.0.1:{args.listen_port} -> {args.upstream_host}:{args.upstream_port}  "
          f"delay={args.delay_ms}ms jitter=+/-{args.jitter_ms}ms loss={args.loss_pct}%", flush=True)

    try:
        while True:
            await asyncio.sleep(5)
            print(f"[proxy] stats: forwarded={proxy.forwarded} dropped={proxy.dropped}", flush=True)
    except asyncio.CancelledError:
        pass


if __name__ == "__main__":
    asyncio.run(main())
