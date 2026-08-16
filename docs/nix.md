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

`nix flake check` builds two test derivations using the same pinned Mix
dependency closure as the packaged relay:

- `checks.<system>.unit` runs the fast ExUnit suite without network access or
  external daemons.
- `checks.<system>.integration` supplies Bitcoin Core, Core Lightning, and
  OpenSSL from Nix, then exercises the actual HTTP/WebSocket/TCP, BOLT-8/CLN,
  and HTTPS paths using temporary local services.

They can also be built independently:

```console
nix build .#checks.$(nix eval --impure --raw --expr builtins.currentSystem).unit
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
            environmentFile = "/run/secrets/zaptunnel-relay";
            tls = {
              enable = true;
              domain = "zapptunnel.com";
              acme = {
                email = "admin@zapptunnel.com";
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

To provide an existing certificate instead, set `tls.acme.enable = false` and
configure `tls.certificateFile` and `tls.privateKeyFile`. Keep TLS keys, DNS
credentials, and other secrets outside the Nix store and provide application
secrets through `environmentFile` or a NixOS secret-management system.
