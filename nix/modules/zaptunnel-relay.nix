{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.zaptunnel-relay;
  acmeDirectory = "/var/lib/acme/${cfg.tls.domain}";
  certificateFile =
    if cfg.tls.acme.enable
    then "${acmeDirectory}/fullchain.pem"
    else cfg.tls.certificateFile;
  privateKeyFile =
    if cfg.tls.acme.enable
    then "${acmeDirectory}/key.pem"
    else cfg.tls.privateKeyFile;
in {
  options.services.zaptunnel-relay = {
    enable = lib.mkEnableOption "the Zaptunnel relay";

    package = lib.mkOption {
      type = lib.types.package;
      description = ''
        Zaptunnel relay release to run. The flake module defaults this to its
        packaged OTP release.
      '';
      example = lib.literalExpression "inputs.zaptunnel.packages.${pkgs.stdenv.hostPlatform.system}.relay";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "zaptunnel";
      description = "User account under which the relay runs.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "zaptunnel";
      description = "Group under which the relay runs.";
    };

    webPort = lib.mkOption {
      type = lib.types.port;
      default = 4000;
      description = "HTTP or HTTPS and WebSocket listener port.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Listener address. TLS-enabled public deployments normally use 0.0.0.0.";
    };

    tls = {
      enable = lib.mkEnableOption "TLS termination inside the Zaptunnel relay";

      domain = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "zapptunnel.com";
        description = "Base DNS name for the relay and its wildcard certificate.";
      };

      certificateFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "PEM certificate chain used when ACME management is disabled.";
      };

      privateKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "PEM private key used when ACME management is disabled.";
      };

      acme = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Issue and renew the wildcard certificate with the NixOS ACME module.";
        };

        email = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "admin@zapptunnel.com";
          description = "Contact email supplied to the ACME certificate authority.";
        };

        dnsProvider = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "cloudflare";
          description = "Lego DNS provider name. DNS-01 is required for the wildcard certificate.";
        };

        credentialFiles = lib.mkOption {
          type = lib.types.attrsOf lib.types.path;
          default = {};
          example = lib.literalExpression ''
            { "CF_DNS_API_TOKEN_FILE" = "/run/secrets/cloudflare-dns-token"; }
          '';
          description = "DNS-provider credential files passed to the NixOS ACME service.";
        };
      };
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the configured listener port in the NixOS firewall.";
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        File containing secret environment variables. It must not be stored in
        the Nix store because store contents are readable by local users.
      '';
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Non-secret environment variables passed to the relay.";
    };

    extraServiceConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = "Additional systemd service settings.";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = !cfg.tls.enable || cfg.tls.domain != "";
          message = "services.zaptunnel-relay.tls.domain is required when TLS is enabled";
        }
        {
          assertion = !cfg.tls.enable || !cfg.tls.acme.enable || cfg.tls.acme.email != null;
          message = "services.zaptunnel-relay.tls.acme.email is required for ACME";
        }
        {
          assertion = !cfg.tls.enable || !cfg.tls.acme.enable || cfg.tls.acme.dnsProvider != null;
          message = "services.zaptunnel-relay.tls.acme.dnsProvider is required for wildcard DNS-01 issuance";
        }
        {
          assertion =
            !cfg.tls.enable
            || cfg.tls.acme.enable
            || (cfg.tls.certificateFile != null && cfg.tls.privateKeyFile != null);
          message = "certificateFile and privateKeyFile are required when TLS is enabled without ACME";
        }
      ];

      users.users = lib.mkIf (cfg.user == "zaptunnel") {
        zaptunnel = {
          isSystemUser = true;
          inherit (cfg) group;
          description = "Zaptunnel relay service account";
        };
      };

      users.groups = lib.mkIf (cfg.group == "zaptunnel") {
        zaptunnel = {};
      };

      networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [cfg.webPort];

      systemd.services.zaptunnel-relay = {
        description = "Zaptunnel relay";
        wantedBy = ["multi-user.target"];
        after =
          ["network-online.target"]
          ++ lib.optional (cfg.tls.enable && cfg.tls.acme.enable) "acme-${cfg.tls.domain}.service";
        wants = ["network-online.target"];
        requires =
          lib.optional (cfg.tls.enable && cfg.tls.acme.enable) "acme-${cfg.tls.domain}.service";

        environment =
          {
            RELEASE_COOKIE = "zaptunnel-local";
            RELEASE_DISTRIBUTION = "none";
            RELEASE_TMP = "/run/zaptunnel-relay";
            ZAPTUNNEL_LISTEN_ADDRESS = cfg.listenAddress;
            ZAPTUNNEL_WEB_PORT = toString cfg.webPort;
          }
          // lib.optionalAttrs cfg.tls.enable {
            ZAPTUNNEL_TLS_CERTFILE = certificateFile;
            ZAPTUNNEL_TLS_KEYFILE = privateKeyFile;
          }
          // cfg.environment;

        serviceConfig =
          {
            Type = "exec";
            ExecStart = "${cfg.package}/bin/zaptunnel_relay start";
            User = cfg.user;
            Group = cfg.group;
            EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile;
            RuntimeDirectory = "zaptunnel-relay";
            StateDirectory = "zaptunnel-relay";
            Restart = "on-failure";
            RestartSec = 5;
            UMask = "0077";

            AmbientCapabilities = lib.optional (cfg.webPort < 1024) "CAP_NET_BIND_SERVICE";
            CapabilityBoundingSet = lib.optional (cfg.webPort < 1024) "CAP_NET_BIND_SERVICE";
            LockPersonality = true;
            MemoryDenyWriteExecute = false;
            NoNewPrivileges = true;
            PrivateDevices = true;
            PrivateTmp = true;
            ProtectClock = true;
            ProtectControlGroups = true;
            ProtectHome = true;
            ProtectHostname = true;
            ProtectKernelLogs = true;
            ProtectKernelModules = true;
            ProtectKernelTunables = true;
            ProtectSystem = "strict";
            RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
            RestrictNamespaces = true;
            RestrictRealtime = true;
            SystemCallArchitectures = "native";
          }
          // cfg.extraServiceConfig;
      };
    }

    (lib.mkIf cfg.tls.enable {
      services.zaptunnel-relay.listenAddress = lib.mkDefault "0.0.0.0";
      services.zaptunnel-relay.webPort = lib.mkDefault 443;
    })

    (lib.mkIf (cfg.tls.enable && cfg.tls.acme.enable) {
      security.acme.acceptTerms = true;
      security.acme.defaults.email = cfg.tls.acme.email;
      security.acme.certs.${cfg.tls.domain} = {
        domain = "*.${cfg.tls.domain}";
        extraDomainNames = [cfg.tls.domain];
        group = cfg.group;
        dnsProvider = cfg.tls.acme.dnsProvider;
        credentialFiles = cfg.tls.acme.credentialFiles;
        reloadServices = ["zaptunnel-relay.service"];
      };
    })
  ]);
}
