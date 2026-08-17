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
    mkRelay = pkgs: let
      project = relayProject pkgs;
      sdk = mkSdk pkgs {};
      releaseSrc = pkgs.runCommand "zaptunnel-relay-source" {} ''
        cp -R ${project.src}/. "$out"
        chmod -R u+w "$out"
        mkdir -p "$out/priv/static"
        cp -R ${sdk}/share/zaptunnel-site/. "$out/priv/static/"
      '';
    in
      pkgs.beamPackages.mixRelease (project
        // {
          src = releaseSrc;
          nativeBuildInputs = with pkgs.beamPackages; [hex rebar3];
        });
    mkSdk = pkgs: {runTests ? false}:
      pkgs.stdenvNoCC.mkDerivation (finalAttrs: {
        pname = "zaptunnel-sdk";
        version = "0.1.0";
        src = pkgs.lib.cleanSourceWith {
          src = ./sdk;
          filter = path: _type: let
            name = baseNameOf path;
          in
            name != "node_modules" && name != "dist";
        };

        pnpmDeps = pkgs.fetchPnpmDeps {
          inherit (finalAttrs) pname version src;
          pnpm = pkgs.pnpm;
          fetcherVersion = 4;
          hash = "sha256-bQgLceyJT+SZ6iL+QieLxWppKgXlALAxWDp6s+e83Vs=";
        };

        nativeBuildInputs = [pkgs.nodejs pkgs.pnpm pkgs.pnpmConfigHook];

        buildPhase = ''
          runHook preBuild
          pnpm build
          runHook postBuild
        '';

        doCheck = runTests;
        checkPhase = ''
          runHook preCheck
          node --test test/*.test.mjs
          runHook postCheck
        '';

        installPhase = ''
          runHook preInstall
          mkdir -p "$out/lib" "$out/bin" "$out/share/zaptunnel-site"
          cp -R dist/lib/. "$out/lib/"
          cp -R dist/index.html dist/assets "$out/share/zaptunnel-site/"
          cp scripts/e2e.mjs "$out/bin/zaptunnel-sdk-e2e.mjs"
          substituteInPlace "$out/bin/zaptunnel-sdk-e2e.mjs" \
            --replace-fail '../dist/lib/index.js' '../lib/index.js'
          runHook postInstall
        '';
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
          gnumake
          opentofu
          doctl
          nixos-rebuild
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
      sdk = mkSdk pkgs {runTests = true;};
    in {
      unit = mkRelayCheck pkgs {
        name = "unit-tests";
        testCommand = "mix test --no-deps-check --exclude integration";
      };

      integration = mkRelayCheck pkgs {
        name = "integration-tests";
        testCommand = ''
          ZAPTUNNEL_SDK_E2E_SCRIPT=${sdk}/bin/zaptunnel-sdk-e2e.mjs \
            mix test --no-deps-check --only integration
        '';
        extraNativeBuildInputs = with pkgs; [bitcoind clightning nodejs openssl];
      };

      sdk-unit = sdk;
    });

    packages = forAllSystems (system: let
      pkgs = pkgsFor system;
      relay = mkRelay pkgs;
      sdk = mkSdk pkgs {};
    in {
      inherit relay sdk;
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

    nixosConfigurations.zapptunnel = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        self.nixosModules.zaptunnel-relay
        ./nix/hosts/zapptunnel-digitalocean.nix
      ];
    };
  };
}
