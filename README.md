# Zaptunnel

Zaptunnel bridges browser WebSockets to publicly reachable Core Lightning peer
ports while leaving the inner BOLT-8 connection end-to-end encrypted between
the browser and CLN.

The public documentation site is `https://zapptunnel.com`; SDK and tunnel
traffic use `https://relay.zapptunnel.com`.

The Svelte documentation and live `getinfo` demo are compiled into the OTP
release and served directly by Bandit. The deployment does not need a separate
website process or reverse proxy.

The current vertical slice includes:

- an Elixir/OTP relay with short-lived admission tickets;
- relay-initiated BOLT-8 endpoint verification with `init` and `ping`/`pong`;
- deduplicated verification caching and bounded verification concurrency;
- a three-connection limit per destination node ID;
- public-address validation, DNS pinning, and v3 onion routing through Tor;
- request rate limiting and bounded frames;
- opaque, bidirectional WebSocket-to-TCP forwarding;
- a typed, importable TypeScript SDK built on `lnmessage`;
- Prometheus metrics at `/metrics`; and
- a reproducible OTP release and NixOS module.

## Development

Enter the pinned toolchain:

```console
nix develop
```

Run relay tests:

```console
cd relay
mix deps.get
mix test
```

`mix test` runs the fast unit suite and excludes tests tagged `integration`.
Run the integration suite separately:

```console
cd relay
mix test --only integration
```

The integration suite starts isolated temporary services and verifies:

- HTTP admission followed by a real WebSocket upgrade and opaque TCP forwarding;
- single-use ticket rejection;
- BOLT-8, `init`, and `ping`/`pong` against a real CLN regtest node;
- rejection when the supplied node ID does not match that CLN endpoint;
- the packaged SDK performing admission, BOLT-8, and Commando `getinfo`
  through the relay against a real CLN node; and
- direct HTTPS termination by Bandit using configured certificate files.

The flake exposes both suites as reproducible offline checks:

```console
nix build .#checks.$(nix eval --impure --raw --expr builtins.currentSystem).unit
nix build .#checks.$(nix eval --impure --raw --expr builtins.currentSystem).sdk-unit
nix build .#checks.$(nix eval --impure --raw --expr builtins.currentSystem).integration
nix flake check
```

Run the relay for local regtest development:

```console
cd relay
ZAPTUNNEL_ALLOW_PRIVATE_ADDRESSES=true mix run --no-halt
```

The development override permits local CLN regtest endpoints, but endpoint
verification still requires the supplied node ID to match the CLN listener.
To use an existing Tor SOCKS5 proxy during development, set both
`ZAPTUNNEL_TOR_SOCKS_ADDRESS` and `ZAPTUNNEL_TOR_SOCKS_PORT`. Onion hostnames
are resolved by that proxy and are never submitted to local DNS.

Build or serve the browser harness:

```console
cd sdk
pnpm install
pnpm test
pnpm dev
```

Use the SDK from an application:

```ts
import { connect } from "@zaptunnel/sdk";

const node = await connect({
  nodeId: "03abc...",
  address: "node.example.com:9735",
  rune: "..."
});

const info = await node.getinfo();
node.disconnect();
```

See [the SDK README](sdk/README.md) for identity persistence, generic RPC
calls, error handling, and local package installation.

Build the packaged OTP release:

```console
nix build .#relay
nix build .#sdk
```

Prometheus can scrape `GET /metrics` on the relay listener. Metrics cover
admission outcomes, rate limiting, endpoint verification, pending and active
sessions, duration, and forwarded byte counts. Node IDs are deliberately not
used as metric labels. Admission responses include an `X-Request-ID` for
correlation with private structured logs; public errors remain intentionally
generic. The DigitalOcean NixOS configuration also provisions a private
Grafana instance and a ready-to-use Zaptunnel operations dashboard; open its
SSH tunnel with `make grafana`.

The development-only `ZAPTUNNEL_ALLOW_PRIVATE_ADDRESSES=true` setting must not
be enabled on a public relay.

See [the architecture](docs/architecture.md) and
[Nix deployment notes](docs/nix.md) for the current design boundaries.

## DigitalOcean deployment

The deployment workflow mirrors the adjacent streamer project. With an active
`doctl` context, provision the droplet, DigitalOcean firewall and DNS, install
the ACME credential, deploy NixOS, and run smoke checks with:

```console
make provision
```

Subsequent application deployments use `make deploy`. Run `make help` to see
the individual provisioning, diagnostics, Prometheus, and teardown commands.
