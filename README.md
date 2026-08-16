# Zaptunnel

Zaptunnel bridges browser WebSockets to publicly reachable Core Lightning peer
ports while leaving the inner BOLT-8 connection end-to-end encrypted between
the browser and CLN.

The current vertical slice includes:

- an Elixir/OTP relay with short-lived admission tickets;
- relay-initiated BOLT-8 endpoint verification with `init` and `ping`/`pong`;
- deduplicated verification caching and bounded verification concurrency;
- a three-connection limit per destination node ID;
- public-address validation, DNS pinning, request rate limiting, and bounded frames;
- opaque, bidirectional WebSocket-to-TCP forwarding;
- a TypeScript `lnmessage` browser harness; and
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
- rejection when the supplied node ID does not match that CLN endpoint; and
- direct HTTPS termination by Bandit using configured certificate files.

The flake exposes both suites as reproducible offline checks:

```console
nix build .#checks.$(nix eval --impure --raw --expr builtins.currentSystem).unit
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

Build or serve the browser harness:

```console
cd sdk
pnpm install
pnpm build
pnpm dev
```

Build the packaged OTP release:

```console
nix build .#relay
```

The development-only `ZAPTUNNEL_ALLOW_PRIVATE_ADDRESSES=true` setting must not
be enabled on a public relay.

See [the architecture](docs/architecture.md) and
[Nix deployment notes](docs/nix.md) for the current design boundaries.
