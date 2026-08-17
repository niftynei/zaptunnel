# Nix development and deployment

Enter the complete development environment with:

```console
nix develop
```

The shell provides Elixir/Erlang, Node.js/pnpm, Bitcoin Core, Core Lightning,
language servers, linters, and Nix formatters. Language-specific caches are
kept under the repository's `.nix/` directory instead of the user's home
directory.

Format and validate Nix files with:

```console
nix fmt .
statix check .
deadnix .
```

## Build checks

`nix flake check` builds relay unit, SDK unit, and integration derivations from
pinned dependency closures:

- `checks.<system>.unit` runs the fast ExUnit suite without network access or
  external daemons.
- `checks.<system>.sdk-unit` builds the distributable SDK and runs its Node.js
  unit tests.
- `checks.<system>.integration` supplies Bitcoin Core, Core Lightning, and
  OpenSSL from Nix, then exercises the actual HTTP/WebSocket/TCP, BOLT-8/CLN,
  packaged SDK/Commando, and HTTPS paths using temporary local services.

They can also be built independently:

```console
nix build .#checks.$(nix eval --impure --raw --expr builtins.currentSystem).unit
nix build .#checks.$(nix eval --impure --raw --expr builtins.currentSystem).sdk-unit
nix build .#checks.$(nix eval --impure --raw --expr builtins.currentSystem).integration
```

## NixOS module

The flake exports `packages.<system>.relay`, `nixosModules.default`, and
`nixosModules.zaptunnel-relay`. The module uses the packaged OTP release by
default:

```nix
{
  inputs.zaptunnel.url = "github:example/zaptunnel";

  outputs = {nixpkgs, zaptunnel, ...}: {
    nixosConfigurations.relay = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        zaptunnel.nixosModules.default
        ({pkgs, ...}: {
          services.zaptunnel-relay = {
            enable = true;
            openFirewall = true;
            websiteHost = "zapptunnel.com";
            relayHost = "relay.zapptunnel.com";
            environmentFile = "/run/secrets/zaptunnel-relay";
            tls = {
              enable = true;
              domain = "zapptunnel.com";
              acme = {
                email = "niftynei+zaptunnel@gmail.com";
                dnsProvider = "cloudflare";
                credentialFiles = {
                  CF_DNS_API_TOKEN_FILE = "/run/secrets/cloudflare-dns-token";
                };
              };
            };
          };
        })
      ];
    };
  };
}
```

With TLS enabled, the relay listens directly on `0.0.0.0:443`. Bandit handles
HTTPS/WSS itself; Caddy, nginx, and HAProxy are not involved. Wildcards require
DNS-01, so select a [lego-supported DNS provider](https://go-acme.github.io/lego/dns/)
and place its token in a runtime secret file. The NixOS ACME service issues and
renews both `*.zapptunnel.com` and `zapptunnel.com`, shares the resulting files
with the `zaptunnel` group, and restarts the relay after renewal.

When `websiteHost` and `relayHost` are set, the same listener serves the
packaged Svelte documentation/demo at the former and the health, metrics,
admission, and WebSocket endpoints at the latter. Requests for other host names
receive `421 Misdirected Request`.

Set `services.zaptunnel-relay.tor.enable = true` to accept v3 onion-service
node addresses. By default the module runs a local Tor client on
`127.0.0.1:9050`, configures an onion-only SOCKS listener with destination
isolation, and orders the relay after `tor.service`. To use a separately
managed SOCKS5 proxy, set `tor.manageService = false` and configure
`tor.socksAddress` and `tor.socksPort`. Use `make status` to inspect both the
relay and Tor units, or `make tor-logs` to follow Tor bootstrap and connection
messages.

The relay drains during service shutdown. `drainTimeoutSeconds` defaults to 30
seconds; increase it if preserving longer-lived sessions during planned
deployments is more important than deployment speed. `/healthz` remains a
liveness endpoint while `/readyz` returns `503` as soon as draining begins.

To provide an existing certificate instead, set `tls.acme.enable = false` and
configure `tls.certificateFile` and `tls.privateKeyFile`. Keep TLS keys, DNS
credentials, and other secrets outside the Nix store and provide application
secrets through `environmentFile` or a NixOS secret-management system.

Prometheus should scrape `https://<relay>/metrics`. The endpoint is served by
Bandit on the same listener as admission and WebSocket traffic, so it requires
no additional firewall port. Aggregate metrics contain no node-ID or address
labels.

## DigitalOcean host

The flake exports `nixosConfigurations.zapptunnel`, using
[`nix/hosts/zapptunnel-digitalocean.nix`](../nix/hosts/zapptunnel-digitalocean.nix).
It is intended for the same `nixos-infect` and `nixos-rebuild --target-host`
flow used by the adjacent streamer project.

The root `Makefile` wraps OpenTofu/Terraform, `doctl`, SSH, and
`nixos-rebuild`. Authenticate once, then run the complete workflow:

```console
doctl auth init
make provision
```

The Makefile identifies `~/.ssh/id_ed25519.pub` by fingerprint. If DigitalOcean
already has that public key under another name, provisioning reuses it instead
of attempting a duplicate import. Set `SSH_PUBLIC_KEY=/path/to/key.pub` to use
a different deployment key.

`make provision` registers the deployment SSH key when needed, creates the
droplet, firewall, and DNS records, waits for `nixos-infect`, pulls the exact
hardware/network configuration, installs the DigitalOcean token for ACME,
deploys the NixOS system, and runs public HTTPS smoke checks.

By default ACME receives the active deployment token. Set
`DIGITALOCEAN_DNS_TOKEN` before deployment to install a separate, restricted
DNS token instead.

The domain must use DigitalOcean DNS. To inspect or run individual stages:

```console
make plan
make create
make wait-for-nixos
make pull-host-config
make deploy
make status
make logs
make smoke
```

The host directly terminates TLS in Bandit and requests both
`zapptunnel.com` and `*.zapptunnel.com` through DNS-01. Public firewall access
is limited to SSH and HTTPS; port 80 is unnecessary.

Create `A` and, if applicable, `AAAA` records for both `zapptunnel.com` and
`relay.zapptunnel.com` pointing to the droplet. The apex is reserved for the
human-facing website; the SDK and API use `https://relay.zapptunnel.com`.

Prometheus retains 30 days of data and scrapes Zaptunnel, node-exporter, and
itself. Grafana is provisioned with Prometheus as its default data source and a
read-only **Zaptunnel Overview** dashboard covering admissions, endpoint
verification failures, sessions, traffic, and host health. Both UIs listen on
loopback only.

Prometheus also evaluates Zaptunnel availability, Tor availability,
verification failures, rate limiting, session capacity, failed systemd units,
CPU, memory, and disk alert rules. Alertmanager groups them and writes firing
and resolved notifications to the system journal. Use `make alert-logs` for
the notification stream or `make alerts` for its private UI. No third-party
notification receiver is configured by default, so adding email, ntfy, or
another destination remains an operator choice rather than a secret embedded
in the Nix store.

Open the Grafana SSH tunnel with:

```console
make grafana
```

Then visit `http://127.0.0.1:3000`. Access is anonymous and read-only because
the service is reachable only through an authenticated SSH connection. For the
raw Prometheus query UI, use:

```console
make prometheus
```

Then visit `http://127.0.0.1:9090`. Run `make help` for deployment, logs,
health, DNS, metrics, and teardown commands.
