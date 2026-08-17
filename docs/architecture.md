# Zaptunnel architecture

## Direct Lightning sessions

The default Zaptunnel path connects directly to a caller-provided CLN
Lightning address:

```text
browser -- WSS --> relay -- TCP --> CLN Lightning peer listener
        <----------- BOLT-8 ----------->
```

The relay terminates the outer TLS and WebSocket transport, but it does not
terminate BOLT-8. It removes and adds WebSocket framing while forwarding the
opaque byte stream. From CLN's perspective, each session is an ordinary
inbound Lightning peer connection followed by ordinary `init` and Commando
messages. No Zaptunnel plugin or node-side protocol extension is involved.

The browser SDK owns the initiator's Lightning session key. Consequently,
CLN sees the browser SDK's peer identity and the relay's network address. The
relay itself has no Lightning peer identity in this connection.

The SDK generates a secp256k1 keypair for the BOLT-8 initiator. By default it
may use an ephemeral key for each connection. Applications that want a stable
peer identity or a rune restricted to a particular peer may provide and
persist their own key through the SDK. The private key never leaves the
browser and is never sent to Zaptunnel.

Zaptunnel is Lightning-protocol agnostic after routing the connection. It
knows the requested destination node ID, selected network address, session
state, and byte counts, but it does not interpret the BOLT-8 handshake,
Lightning messages, Commando requests, runes, or responses. The destination
node ID remains metadata because it is needed for routing, expected-responder
selection by the SDK, and connection-limit accounting.

Every version 1 connection request must provide:

- the expected destination node public key; and
- a publicly dialable `host:port` address.

The relay performs no gossip lookup or automatic address discovery. A request
without an address fails with a stable, machine-readable `address_required`
error. Version 1 therefore does not require the relay operator to run a CLN
node or maintain a gossip graph.

Version 1 also has no node-side agent or reverse-connect path. A node must be
reachable by the relay at the supplied address.

A supplied address is only a routing hint. The requested node public key is
always the expected BOLT-8 responder identity. Private, loopback, link-local,
multicast, and reserved destinations must be rejected to prevent SSRF.
Hostnames must be resolved by the relay, validated after resolution, and
dialed using a pinned validated address so DNS rebinding cannot change the
destination between validation and connection. Onion addresses are not
supported unless a Tor dialer is explicitly added later.

Accepting arbitrary addresses creates an open-proxy risk even though the
browser ultimately authenticates the destination through BOLT-8. Before
relaying arbitrary session bytes, the relay opens a separate, short-lived
Lightning connection to the supplied endpoint. It performs BOLT-8 as the
initiator while expecting the requested node public key, exchanges `init`,
sends a Lightning `ping`, and requires the corresponding `pong`. A successful
BOLT-8 handshake proves possession of the requested node key; `init` and
`pong` additionally establish that the endpoint is a live Lightning peer.

Successful endpoint checks may be cached briefly by node ID and resolved
address. Concurrent checks for the same tuple are coalesced into one probe,
successful checks are cached for ten minutes, and failures for fifteen
seconds. The validation connection is separate from the browser's
end-to-end session and is closed before admission. The verifier uses a fresh,
unfunded initiator key. The relay still does not terminate or inspect the
browser's BOLT-8 connection.

Admission requests are subject to a per-source-IP token bucket before DNS or
cryptographic work begins. DNS resolution, endpoint verification, ticket
redemption, the number of concurrent verification workers, WebSocket frame
size, total relay sessions, and session inactivity are all bounded by
configuration. Telemetry events expose verification duration/results, cache
hits, rate-limit rejections, and per-session duration and byte counts. Error details
from a failed network probe are intentionally collapsed into
`endpoint_unverified` so that the API is less useful as a scanning oracle.

The relay serves Prometheus text exposition at `/metrics`. It reports
aggregate admission outcomes, rate-limit rejections, endpoint verification
results and duration, pending and active slots, session lifecycle, and byte
counts. Node IDs and addresses are never Prometheus labels: they would leak
routing metadata and create an attacker-controlled cardinality problem.

## Free connection limit

The first release permits at most **three concurrent sessions per destination
node public key**. This is a global destination limit, not a per-IP or
per-browser limit.

These slots are intentionally public shared infrastructure. Version 1 does
not require a node-owner account, caller authorization, or payment. Its abuse
model relies on bounded resources, rate limits, establishment deadlines, and
operational blocking rather than trying to make the free tier unavailable to
untrusted callers.

A session consumes a slot while it is pending or active. Slot acquisition and
release must be atomic so simultaneous requests cannot exceed the limit. A
slot is released when either side disconnects, establishment times out, or the
session process terminates. Pending sessions have a short handshake timeout so
an incomplete WebSocket or BOLT-8 connection cannot hold a slot indefinitely.

The relay should return a stable, machine-readable `connection_limit` error
when all free slots are occupied. Version 1 has no paid override. A later
version may respond with `payment_required` and a quote for additional
capacity. Successful payment produces a short-lived, single-use admission
token bound to the destination node, supplied address, and connection request.
Payment and admission happen before the WebSocket session, so adding them does
not change BOLT-8 or give the relay access to tunneled traffic.

The endpoint handshake authenticates the destination, not the browser asking
for a connection. The three free slots are therefore a public shared allowance
for that destination and can be exhausted by callers who know its node ID and
address. At minimum, the relay must:

- rate-limit session creation separately from concurrent sessions;
- apply strict WebSocket and BOLT-8 establishment deadlines;
- close sessions that never exchange traffic after establishment;
- cap pending sessions independently from active sessions; and
- emit per-destination occupancy and rejection metrics.

Long-lived, healthy Lightning sessions should not be disconnected merely to
rotate free capacity.

## Outer TLS

Bandit terminates HTTPS and WSS directly in the relay process. There is no
required reverse proxy. The application accepts a certificate-chain path and
private-key path at runtime; it never performs ACME account or DNS-provider
operations itself.

On NixOS, the Zaptunnel module declaratively configures the standard NixOS
ACME service to issue `*.zapptunnel.com` (plus the zone apex) with DNS-01. The
ACME unit owns issuance and renewal, grants the Zaptunnel group read access,
and restarts the relay after renewal so Bandit loads the new files. DNS API
credentials remain in runtime secret files and never enter the Nix store.

The public website lives at `https://zapptunnel.com`; SDK admission and WSS
traffic use `https://relay.zapptunnel.com`. Both names may resolve to the same
Bandit listener. The apex-plus-wildcard certificate covers both, and the
application can route the documentation site and relay API by HTTP Host
without adding a reverse proxy.

## Deferred: CLNRest

Version 1 supports only BOLT-8 Lightning sessions carrying Commando. CLNRest
support is deferred to version 2.

CLNRest is a separate transport and trust mode rather than another message
type on the version 1 tunnel. Standard browser HTTPS requires TLS to terminate
at either the relay or a node-side endpoint. Relay termination exposes REST
requests, runes, and responses to the relay. Node-side termination requires a
node agent or CLN certificate configuration and does not provide the same
hostile-relay guarantee when the relay controls the parent DNS zone and a
valid wildcard certificate. Version 2 must present that distinction
explicitly rather than describing CLNRest as equivalent to the blind BOLT-8
path.

## Deferred: private-node reachability

Version 1 cannot reach a node behind NAT or CGNAT when it has no publicly
dialable address. Supporting those nodes later would require a reverse-dialing
agent, a CLN plugin with equivalent behavior, or another rendezvous transport.
That component is not part of the version 1 build or development toolchain.

## Deferred: address discovery

Version 1 always requires a caller-provided address. Later releases may look
up node addresses from Lightning gossip, a relay-operated CLN node, a signed
directory, or another discovery mechanism. Automatic lookup must be treated
as routing metadata only: the browser continues to authenticate the responder
against the requested node public key through BOLT-8.
