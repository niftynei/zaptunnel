# @zaptunnel/sdk

Connect browser applications to Core Lightning over an end-to-end encrypted
BOLT-8 session forwarded by Zaptunnel.

This package also builds the Svelte documentation and live `getinfo` demo.
The production OTP release serves it at `zapptunnel.com`, while SDK traffic
uses `relay.zapptunnel.com`.

```ts
import { connect } from "@zaptunnel/sdk";

const node = await connect({
  nodeId: "03abc...",
  address: "node.example.com:9735",
  rune: "..."
});

const info = await node.getinfo();
const invoice = await node.invoice({
  amount_msat: 1_000,
  label: crypto.randomUUID(),
  description: "example"
});

node.disconnect();
```

The default relay is `https://relay.zapptunnel.com`. Set `relay` to use a
self-hosted deployment. `call(method, params)` supports any
Commando-accessible CLN RPC.
An individual call can override the default rune:

```ts
await node.call("invoice", params, { rune: invoiceOnlyRune });
```

## Browser identity

By default every connection receives a new, ephemeral BOLT-8 initiator key. To
give the browser a stable peer identity, persist `node.privateKey` securely and
pass it as `privateKey` on the next connection. The key never passes through
the Zaptunnel relay.

## Errors

`ZaptunnelError` exposes a stable `code` and, for admission failures, the HTTP
`status`. Current relay codes include `rate_limited`, `connection_limit`,
`endpoint_unverified`, and `relay_overloaded`.

## Local development

```console
pnpm test
pnpm pack
```

Install the resulting tarball in another project until the package is
published to npm.
