{
  description = "Zaptunnel development environment and deployment modules";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = {
    self,
    nixpkgs,
    ...
  }: let
    supportedSystems = [
      "aarch64-darwin"
      "aarch64-linux"
      "x86_64-darwin"
      "x86_64-linux"
    ];

    forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    pkgsFor = system: import nixpkgs {inherit system;};
    relayProject = pkgs: let
      pname = "zaptunnel-relay";
      version = "0.1.0";
      src = pkgs.lib.cleanSource ./relay;
      mixFodDeps = pkgs.beamPackages.fetchMixDeps {
        inherit pname version src;
        hash = "sha256-349KseHrYKUguXIhV0scIqsZPWwKD87gCqZUHmTtX+M=";
      };
    in {
      inherit pname version src mixFodDeps;
    };
    mkRelay = pkgs:
      pkgs.beamPackages.mixRelease ((relayProject pkgs)
        // {
          nativeBuildInputs = with pkgs.beamPackages; [hex rebar3];
        });
    mkRelayCheck = pkgs: {
      name,
      testCommand,
      extraNativeBuildInputs ? [],
    }: let
      project = relayProject pkgs;
    in
      pkgs.beamPackages.mixRelease {
        pname = "zaptunnel-relay-${name}";
        inherit (project) version src mixFodDeps;
        mixEnv = "test";

        nativeBuildInputs =
          (with pkgs.beamPackages; [hex rebar3])
          ++ extraNativeBuildInputs;

        buildPhase = ''
          runHook preBuild
          ${testCommand}
          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          mkdir -p "$out/bin"
          touch "$out/tests-passed"
          runHook postInstall
        '';
      };
  in {
    devShells = forAllSystems (system: let
      pkgs = pkgsFor system;
    in {
      default = pkgs.mkShell {
        name = "zaptunnel";

        packages = with pkgs; [
          # Elixir relay
          beamPackages.elixir
          beamPackages.erlang
          beamPackages.hex
          rebar3
          elixir-ls

          # TypeScript browser SDK
          nodejs
          pnpm

          # Local Lightning regtest
          bitcoind
          clightning

          # Native build dependencies
          pkg-config
          openssl

          # Repository tooling
          git
          just
          alejandra
          statix
          deadnix
          shellcheck
        ];

        shellHook = ''
          export MIX_HOME="$PWD/.nix/mix"
          export HEX_HOME="$PWD/.nix/hex"
          export REBAR_CACHE_DIR="$PWD/.nix/rebar3"
          export PNPM_HOME="$PWD/.nix/pnpm"
          export PATH="$PNPM_HOME:$PATH"
        '';
      };
    });

    formatter = forAllSystems (system: (pkgsFor system).alejandra);

    checks = forAllSystems (system: let
      pkgs = pkgsFor system;
    in {
      unit = mkRelayCheck pkgs {
        name = "unit-tests";
        testCommand = "mix test --no-deps-check --exclude integration";
      };

      integration = mkRelayCheck pkgs {
        name = "integration-tests";
        testCommand = "mix test --no-deps-check --only integration";
        extraNativeBuildInputs = with pkgs; [bitcoind clightning openssl];
      };
    });

    packages = forAllSystems (system: let
      relay = mkRelay (pkgsFor system);
    in {
      inherit relay;
      default = relay;
    });

    nixosModules = let
      module = {pkgs, ...}: {
        imports = [./nix/modules/zaptunnel-relay.nix];
        services.zaptunnel-relay.package =
          nixpkgs.lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.relay;
      };
    in {
      default = module;
      zaptunnel-relay = module;
    };
  };
}
