# Zaptunnel architecture

## Direct Lightning sessions

The default Zaptunnel path connects directly to a caller-provided CLN
Lightning address:

```text
browser -- WSS --> relay -- TCP/Tor --> CLN Lightning peer listener
        <------------- BOLT-8 ------------->
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
- a publicly dialable clearnet `host:port` or v3 onion-service address.

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
destination between validation and connection.

Valid 56-character v3 `.onion` hostnames are preserved instead of being sent
to the system DNS resolver. When Tor support is enabled, the relay hands the
hostname to its loopback SOCKS5 proxy using the SOCKS domain-name address type.
The endpoint-verification probe and admitted browser session share this dialer,
so the address is authenticated and used over the same transport. Legacy v2
and malformed onion names are rejected locally. If no Tor proxy is configured,
onion admission fails closed with `onion_unavailable`.

The NixOS module can run a dedicated Tor client whose SOCKS listener accepts
onion traffic only and isolates circuits by destination address and port. Tor
does not hide the browser from Zaptunnel: the relay still observes the browser
IP, requested node ID, onion hostname, timing, and byte counts. It does prevent
local DNS leakage of the onion hostname and allows the relay to reach a node
that exposes only an onion service.

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
Every response carries an opaque `X-Request-ID`; error JSON repeats it as
`request_id`. Private operator logs use that ID to correlate the admission
outcome with a bounded verification stage and reason such as `tcp_connect /
econnrefused`, `bolt8_handshake / authentication_failed`, `init / timeout`, or
`ping / message_limit`. Submitted addresses are escaped before logging, node
IDs are abbreviated, and runes, RPC payloads, Lightning packets, and browser
credentials are never logged.

`GET /healthz` is a liveness check; `GET /readyz` reports whether the process
is accepting new admissions. On graceful shutdown the application first marks
admission as draining, so readiness becomes `503` and new tickets receive
`relay_draining`. Previously issued tickets may still be claimed and existing
sessions continue until they close or the configured drain deadline expires.
The NixOS service gives the application additional stop time beyond that
deadline before systemd terminates it.

The relay serves Prometheus text exposition at `/metrics` only to loopback
clients. It reports
aggregate admission outcomes, rate-limit rejections, endpoint verification
results and duration, pending and active slots, session lifecycle, and byte
counts. Node IDs and addresses are never Prometheus labels: they would leak
routing metadata and create an attacker-controlled cardinality problem.
Verification failure metrics use only bounded `stage` and `reason` labels.

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
release are atomic so simultaneous requests cannot exceed the limit. Only one
unclaimed free ticket may exist per destination at a time. A slot is released
when its short-lived ticket expires, either side disconnects, or the session
process terminates. Because the relay cannot distinguish an inner BOLT-8
handshake from other encrypted bytes, it enforces byte and idle limits rather
than claiming to enforce a BOLT-8 establishment deadline.

When all free slots are occupied, a payment-enabled relay returns
`payment_required` with one BOLT11 invoice represented through both MPP and
L402. Successful payment produces an expiring lease bound to the destination
node. One lease permits one concurrent logical connection and can be reused
for transport reconnects until expiry. Payment and admission happen before the
WebSocket session, so this does not change BOLT-8 or give the relay access to
tunneled traffic.

Wallets that return a preimage redeem through MPP or L402. For QR and external
wallets, each quote also has an independent 256-bit claim secret; only its hash
is stored. One background billing watcher advances a durable CLN
`waitanyinvoice` cursor and marks matching quotes paid. Browsers poll the claim
endpoint and receive the same idempotent lease after settlement. Quote ID alone
never authorizes a claim, and claim secrets must not appear in URLs, logs, or
metrics.

The endpoint handshake authenticates the destination, not the browser asking
for a connection. The three free slots are therefore a public shared allowance
for that destination and can be exhausted by callers who know its node ID and
address. At minimum, the relay must:

- rate-limit session creation separately from concurrent sessions;
- expire unclaimed WebSocket tickets promptly and apply session idle limits;
- close sessions that never exchange traffic after establishment;
- cap pending sessions independently from active sessions; and
- emit aggregate occupancy and rejection metrics without destination labels.

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
