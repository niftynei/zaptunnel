# @zaptunnel/sdk

Connect browser applications to Core Lightning over an end-to-end encrypted
BOLT-8 session forwarded by Zaptunnel. The relay routes encrypted Lightning
messages; it cannot read the rune, RPC method, parameters, or result.

## Install

```console
npm install @zaptunnel/sdk
```

## Connect and call CLN

```ts
import { connect } from "@zaptunnel/sdk";

const node = await connect({
  nodeId: "03abc...",
  address: "node.example.com:9735",
  rune: "..."
});

const info = await node.getinfo();
const funds = await node.call("listfunds");

node.disconnect();
```

The default relay is `https://relay.zapptunnel.com`. Set `relay` to use a
self-hosted deployment. `address` may be a public clearnet endpoint or a v3
onion-service endpoint such as `<56 base32 characters>.onion:9735`; Tor routing
is performed by the relay while BOLT-8 remains end-to-end. `call<T>(method,
params)` supports every RPC method
that the connected node exposes through Commando; the SDK does not maintain a
version-specific copy of CLN's entire RPC schema. `getinfo`, `invoice`, and
invoice waiting have typed convenience methods. Supply a response type to the
generic method when useful:

```ts
type ListFunds = { channels: Array<{ peer_id: string; connected: boolean }> };
const funds = await node.call<ListFunds>("listfunds");
```

## Compatibility

The SDK targets current evergreen browsers with WebSocket, Web Crypto,
`AbortController`, and async-generator support. It talks to CLN's Lightning
peer port using BOLT 8 and invokes RPC through the Commando plugin; it does not
use CLN REST. The requested RPC must exist on the node and the supplied rune
must authorize it.

| SDK | Relay | Address support | Notable APIs |
|---|---|---|---|
| `0.4.x` | Current relay recommended | Clearnet and v3 onion | Resilient connection manager and all `0.3.x` features |
| `0.3.x` | Current relay recommended | Clearnet and v3 onion | Request IDs, connection status, gossip suppression, paid-invoice iterator |
| `0.2.x` | Initial public relay | Clearnet | Generic RPC calls, capability/version gates, paid-invoice iterator |
| `0.1.x` | Initial public relay | Clearnet | Generic RPC calls |

Newer SDKs remain usable with an older relay for features that relay supports;
for example, a missing request ID is represented as `undefined`. Onion
addresses require a relay configured with Tor. Because CLN plugins and RPC
methods vary independently of the core version, use `getCapabilities()` before
depending on optional methods.

## Paid connection leases

The public relay allows three concurrent free connections to a destination
node. When those slots are occupied, it can offer the same BOLT11 invoice as
both an MPP Lightning `charge` challenge and an L402 challenge. Supply a wallet
adapter to pay from the application side:

```ts
const node = createConnectionManager({
  nodeId,
  address,
  rune,
  payment: {
    protocol: "auto", // prefers MPP; "mpp" and "l402" are also accepted
    payInvoice: async (challenge) => {
      showPrice(`${challenge.amountSats} sats`);
      const result = await wallet.sendPayment(challenge.invoice);
      return result.preimage;
    }
  }
});
```

When the wallet returns a 32-byte payment preimage, the SDK immediately redeems
it through the selected MPP or L402 envelope. The SDK never receives wallet
keys. After the relay verifies payment, it returns a paid lease and the
connection manager automatically uses that lease for later transport reconnects
without paying again. A lease permits one concurrent logical connection and
expires according to the relay's quoted terms.

External wallets and QR flows can return `void`. The SDK then polls the relay,
which observes settlement on its billing CLN node:

```ts
let pendingClaim;

const node = createConnectionManager({
  nodeId,
  address,
  rune,
  payment: {
    payInvoice: async (challenge) => {
      showLightningQr(challenge.invoice);
      // No preimage is available in this browser.
    },
    store: {
      loadClaim: () => pendingClaim,
      saveClaim: (_nodeId, claim) => { pendingClaim = claim; },
      clearClaim: () => { pendingClaim = undefined; }
    },
    onStatus: (status) => renderPaymentStatus(status)
  }
});
```

The optional store allows a page reload to recover the same payment and lease
without paying again. A stored claim contains a bearer secret: keep it out of
URLs and logs, and use protected application storage. The SDK deliberately does
not choose `localStorage` on the application's behalf.

Without `payment.payInvoice`, admission throws
`ZaptunnelPaymentRequiredError`. Its safe `challenge` property contains no
claim secret and can be rendered as a QR code or passed to a payment UI.

The HTTP envelopes follow the evolving
[MPP Lightning charge draft](https://paymentauth.org/draft-lightning-charge-00.html)
and the [L402 protocol](https://docs.lightning.engineering/the-lightning-network/l402/protocol-specification).
Both formats redeem the same relay quote and produce the same scoped lease; they
do not create separate products or prices.

## Resilient connections

Use a connection manager for long-lived web and mobile applications. Every
retry requests fresh relay admission and creates a new BOLT-8 session; this is
required because a relay WebSocket ticket is single-use.

```ts
import { createConnectionManager } from "@zaptunnel/sdk";

const node = createConnectionManager({
  nodeId,
  address,
  rune,
  retry: {
    minDelayMs: 1_000,
    maxDelayMs: 30_000,
    jitter: 0.2
  },
  identityStore: {
    loadPrivateKey: (id) => localStorage.getItem(`zaptunnel:${id}:node-key`) ?? undefined,
    savePrivateKey: (id, key) => localStorage.setItem(`zaptunnel:${id}:node-key`, key)
  }
});

const stopWatching = node.onConnectionStatus((status) => {
  // idle | connecting | connected | waiting_reconnect | failed | stopped
  renderConnectionState(status);
});

await node.start();
const info = await node.getinfo();

// stop() is terminal for this manager instance.
node.stop();
stopWatching();
```

The default policy retries forever with exponential backoff, 20% jitter, and a
30-second ceiling. The manager also retries promptly when the browser reports
that it is online again or returns to the foreground. Set a finite
`maxAttempts` when an application wants a terminal `failed` state; call
`retryNow()` after that state to begin a fresh retry cycle.

The identity store receives only the browser's BOLT-8 initiator private key.
It never receives the rune. `localStorage` is convenient but readable by any
script executing on the same origin, so applications with a stronger threat
model should provide an encrypted or platform-backed store.

Treat a Commando rune as a bearer credential, even when it is read-only. Prefer
a narrowly scoped rune with an expiry, keep it in memory for the shortest
practical time, and provide a clear revoke/replace path. Avoid `localStorage`,
URLs, analytics, crash reports, and ordinary application logs. If an app must
survive reloads, encrypt the rune with a non-extractable Web Crypto key stored
in IndexedDB or retrieve it after user authentication; this reduces at-rest
exposure but cannot protect a rune from script already executing in the origin.

Calls made through the manager wait for a connection, then execute exactly
once. The manager deliberately does **not** replay `invoice`, `pay`, or any
other RPC after an ambiguous connection failure. Application code must decide
whether a particular operation is safe to retry.

The manager's `paidInvoices()` iterator is reconnect-safe because CLN's
`pay_index` is monotonic:

```ts
for await (const invoice of node.paidInvoices({
  lastPayIndex: await loadPayIndex(),
  signal: controller.signal
})) {
  await processInvoiceIdempotently(invoice);
  await savePayIndex(invoice.pay_index);
}
```

It carries the latest cursor into every replacement session. Persist the cursor
after processing each invoice to recover across a reload or application
restart; consumers should still be idempotent because a crash before saving can
redeliver the last invoice.

### Gossip suppression

After every BOLT-8 initialization (including manager-created replacement sessions), the SDK
sends a BOLT 7 `gossip_timestamp_filter` with `first_timestamp = 0xffffffff`
and `timestamp_range = 0`. Zaptunnel uses the connection for Commando rather
than network routing, so it does not request relayed historical or ongoing
gossip that the browser would otherwise decrypt and discard.

The SDK uses the first chain hash advertised by the node's BOLT `networks` init
TLV. Bitcoin mainnet is the protocol default when that TLV is absent. A
non-mainnet node that omits `networks` can be configured explicitly with its
unreversed, wire-order hash:

```ts
const node = await connect({
  nodeId,
  address,
  rune,
  chainHash: regtestChainHash
});
```

The filter affects future *relayed* gossip. BOLT 7 permits a node to send
announcements it generated itself regardless of the filter, so the SDK still
safely ignores unsolicited gossip messages that arrive. This behavior is
entirely end-to-end between the browser and CLN; the relay remains unaware of
the message.

An individual call can override the default rune and set local controls:

```ts
const controller = new AbortController();

await node.call("invoice", params, {
  rune: invoiceOnlyRune,
  timeoutMs: 10_000,
  signal: controller.signal
});
```

## Paid-invoice notifications

CLN's `waitanyinvoice` RPC works through Commando. `paidInvoices()` wraps it as
an async iterator and automatically resumes after normal long-poll timeouts:

```ts
const controller = new AbortController();

for await (const invoice of node.paidInvoices({
  lastPayIndex: previouslySavedPayIndex,
  signal: controller.signal
})) {
  console.log(`${invoice.label} received ${invoice.amount_received_msat}msat`);
  await savePayIndex(invoice.pay_index);
}

// Stops the iterator locally.
controller.abort();
```

`pay_index` is monotonic. Save the last processed value and pass it back after
a page reload or reconnect; CLN will return every later paid invoice in order,
including invoices paid while the app was offline. Do not use an in-memory-only
cursor when processing a payment exactly once matters.

You can also perform one long poll directly:

```ts
const invoice = await node.waitAnyInvoice({
  lastPayIndex: 42,
  waitTimeoutSeconds: 30
});
```

### How cancellation works

An `AbortSignal` or `timeoutMs` stops the JavaScript caller from waiting, but
the current `lnmessage` transport cannot send a cancellation for a Commando
request that is already in flight. For that reason, `paidInvoices()` uses a
finite CLN-side timeout (30 seconds by default). An aborted poll may remain at
the node until that timeout expires, but it cannot deliver a result to the
stopped iterator.

Other `wait*` RPCs can be invoked with `call()` too. `waitinvoice` is useful for
one known label. The generic `wait` RPC appeared in CLN v23.08 and has had
response-shape changes, so check capabilities and CLN's versioned documentation
before depending on it. Native CLN plugin event notifications are not forwarded
by Commando; `waitanyinvoice` is the recommended Zaptunnel mechanism for paid
invoice events.

## Capabilities and CLN versions

Plugins and configuration can add or remove methods, so detecting the node's
actual RPC surface is safer than guessing from a version number:

```ts
const capabilities = await node.getCapabilities();

if (capabilities.supports("waitanyinvoice")) {
  // Safe to use the invoice iterator.
}

capabilities.require("listoffers");       // throws unsupported_method
capabilities.requireVersion("v24.02");   // throws unsupported_cln_version
```

`getCapabilities()` calls both `getinfo` and `help`, so its rune must authorize
both methods. The `createrune` command shown on zapptunnel.com requires CLN
v23.08 or newer. Prefer `supports()` for method gates; use version checks only
when behavior or a response field changed within an existing method.

## Stable errors

All SDK errors extend `ZaptunnelError` and expose a stable string `code`.
Relay and connection errors also expose `requestId` when the relay supplied one;
include that identifier in bug reports so an operator can find the matching
verification and session logs without receiving your rune or RPC payload.
RPC failures are `ZaptunnelRpcError` instances and additionally preserve the
RPC `method`, CLN numeric `rpcCode`, and optional `data`.

| Stable code | Meaning |
|---|---|
| `rune_required` | No default or per-call rune was supplied |
| `rune_not_authorized` | CLN/Commando rejected the rune |
| `method_not_found` | The connected node does not expose the RPC |
| `invalid_params` | CLN rejected the RPC parameters |
| `rpc_timeout` | A CLN-side wait reached its deadline |
| `request_timeout` | The SDK stopped waiting at the local deadline |
| `request_aborted` | The supplied `AbortSignal` was aborted |
| `connection_failed` | CLN could not complete the requested connection |
| `payment_required` | Free slots are occupied and the relay offered a Lightning invoice |
| `payment_failed` | The application wallet did not complete payment |
| `invalid_preimage` | The supplied payment proof does not match the invoice |
| `payment_expired` | An external-wallet invoice was not observed as paid before its grace period ended |
| `invalid_claim` | A saved external-wallet claim secret is invalid or no longer exists |
| `payment_status_unavailable` | The relay cannot currently reconcile settlement with its billing node |
| `invalid_lease` | The paid lease is invalid, expired, or scoped to another node |
| `lease_in_use` | The paid lease already has a pending or active connection |
| `invalid_chain_hash` | `chainHash` is not a 32-byte hexadecimal BOLT chain hash |
| `gossip_filter_failed` | The initialized transport could not send its BOLT 7 filter |
| `rpc_failed` | Another CLN RPC failure |
| `unsupported_method` | A capability requirement was not met |
| `unsupported_cln_version` | A version requirement was not met |
| `reconnect_exhausted` | A manager reached its configured finite attempt limit |
| `manager_stopped` | An operation waited on a manager that was permanently stopped |

Relay admission errors use the same base class. Current codes include
`rate_limited`, `connection_limit`, `endpoint_unverified`, `onion_unavailable`,
`relay_draining`, and
`relay_overloaded`. Code should branch on `error.code`, not message text:

```ts
import { ZaptunnelError, ZaptunnelRpcError } from "@zaptunnel/sdk";

try {
  await node.getinfo();
} catch (error) {
  if (error instanceof ZaptunnelRpcError && error.code === "rune_not_authorized") {
    // Ask for a new, narrowly scoped rune.
  } else if (error instanceof ZaptunnelError) {
    console.error(error.code, error.requestId, error.message);
  }
}
```

## Connection troubleshooting

Use `diagnoseZaptunnelError()` when showing a failure to a person. It returns a
safe summary, a failure stage, concrete suggestions, retryability, and the relay
request ID without exposing a rune or raw internal error text:

```ts
import { diagnoseZaptunnelError } from "@zaptunnel/sdk";

try {
  await node.getinfo();
} catch (error) {
  const diagnostic = diagnoseZaptunnelError(error);
  showConnectionProblem({
    title: diagnostic.title,
    detail: diagnostic.summary,
    suggestions: diagnostic.suggestions,
    requestId: diagnostic.requestId
  });
}
```

The `stage` value separates invalid input, relay admission, endpoint
verification, the Lightning handshake, rune authorization, RPC execution, and
manager lifecycle failures. When a finite retry policy ends,
`code` is `reconnect_exhausted` while `causeCode` and `stage` retain the useful
underlying failure.

Long-lived applications can render retries without parsing status strings:

```ts
const stopWatching = node.onConnectionState((state) => {
  renderConnectionState({
    status: state.status,
    attempt: state.attempt,
    retryInMs: state.retryInMs,
    diagnostic: state.diagnostic
  });
});

// After the user fixes an address, Tor, or connectivity problem:
node.retryNow();
```

`nextRetryAt` is an absolute Unix timestamp in milliseconds. `retryInMs` is the
remaining delay when that snapshot was produced; read `node.connectionState`
again to update a live countdown. A request ID is safe to give the Zaptunnel
operator for log correlation. Never include the rune or browser private key in
a support report.

## Single-session connection status

Use the stable status callback to update UI or detect a lost connection without
depending on `lnmessage` internals:

```ts
const stopWatching = node.onConnectionStatus((status) => {
  // connected | connecting | waiting_reconnect | disconnected | failed
  console.log(status);
});

stopWatching();
```

`node.requestId` identifies the admission/session that created this client.
For resilient applications, prefer the manager status API documented above.

## Browser identity

By default every connection receives a new, ephemeral BOLT-8 initiator key. To
give the browser a stable peer identity, persist `node.privateKey` securely and
pass it as `privateKey` on the next connection. The key never passes through
the Zaptunnel relay. It does not authorize CLN RPCs or control funds, but it is
a stable identity/linkability secret. Prefer platform-backed or encrypted
storage; do not serialize the client object or include the key in telemetry.

The optional SDK logger receives only payload-free messages authored by the
Zaptunnel wrapper. Raw `lnmessage` logs are deliberately suppressed because
upstream info-level messages can include complete RPC parameters and CLN error
text.

## Recommended references

- [Core Lightning RPC reference](https://docs.corelightning.org/reference/)
- [BOLT 7 gossip and `gossip_timestamp_filter`](https://github.com/lightning/bolts/blob/master/07-routing-gossip.md#the-gossip_timestamp_filter-message)
- [Commando RPC](https://docs.corelightning.org/reference/commando) and [Commando plugin guide](https://docs.corelightning.org/docs/commando-plugin)
- [`waitanyinvoice`](https://docs.corelightning.org/reference/waitanyinvoice), [`waitinvoice`](https://docs.corelightning.org/reference/waitinvoice), and [`wait`](https://docs.corelightning.org/reference/wait)
- [CLN event notifications](https://docs.corelightning.org/docs/event-notifications)
- [`help`](https://docs.corelightning.org/reference/help) for runtime method discovery
- [`createrune`](https://docs.corelightning.org/reference/createrune) for least-privilege access
- [CLN deprecated features](https://docs.corelightning.org/docs/deprecated-features) when upgrading a node

## Local development

```console
pnpm test
pnpm pack
```

The package also builds the Svelte documentation and live `getinfo` demo served
at `zapptunnel.com`.
