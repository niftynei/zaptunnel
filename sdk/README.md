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
self-hosted deployment. `call<T>(method, params)` supports every RPC method
that the connected node exposes through Commando; the SDK does not maintain a
version-specific copy of CLN's entire RPC schema. `getinfo`, `invoice`, and
invoice waiting have typed convenience methods. Supply a response type to the
generic method when useful:

```ts
type ListFunds = { channels: Array<{ peer_id: string; connected: boolean }> };
const funds = await node.call<ListFunds>("listfunds");
```

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
| `rpc_failed` | Another CLN RPC failure |
| `unsupported_method` | A capability requirement was not met |
| `unsupported_cln_version` | A version requirement was not met |

Relay admission errors use the same base class. Current codes include
`rate_limited`, `connection_limit`, `endpoint_unverified`, and
`relay_overloaded`. Code should branch on `error.code`, not message text:

```ts
import { ZaptunnelError, ZaptunnelRpcError } from "@zaptunnel/sdk";

try {
  await node.getinfo();
} catch (error) {
  if (error instanceof ZaptunnelRpcError && error.code === "rune_not_authorized") {
    // Ask for a new, narrowly scoped rune.
  } else if (error instanceof ZaptunnelError) {
    console.error(error.code, error.message);
  }
}
```

## Browser identity

By default every connection receives a new, ephemeral BOLT-8 initiator key. To
give the browser a stable peer identity, persist `node.privateKey` securely and
pass it as `privateKey` on the next connection. The key never passes through
the Zaptunnel relay.

## Recommended references

- [Core Lightning RPC reference](https://docs.corelightning.org/reference/)
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
