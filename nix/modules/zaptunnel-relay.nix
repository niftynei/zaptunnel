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
          example = "niftynei+zaptunnel@gmail.com";
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

    websiteHost = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "zapptunnel.com";
      description = "Host name that serves the packaged documentation and demo site.";
    };

    relayHost = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "relay.zapptunnel.com";
      description = "Host name that serves the relay HTTP and WebSocket API.";
    };

    drainTimeoutSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = "Maximum time to wait for pending and active sessions during shutdown.";
    };

    payments = {
      enable = lib.mkEnableOption "MPP and L402 Lightning payments for additional connections";

      priceSats = lib.mkOption {
        type = lib.types.ints.positive;
        default = 10;
        description = "Price of one additional reconnect-safe connection lease, in satoshis.";
      };

      network = lib.mkOption {
        type = lib.types.enum ["mainnet" "regtest" "signet"];
        default = "mainnet";
        description = "Lightning network advertised in MPP payment challenges.";
      };

      quoteTtlSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 300;
        description = "Maximum lifetime of a connection payment challenge.";
      };

      leaseTtlSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 28800;
        description = "Lifetime of a paid logical connection lease, including reconnects.";
      };

      claimGraceSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 60;
        description = "Grace period for discovering payments made immediately before invoice expiry.";
      };

      quoteRetentionSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 86400;
        description = "Retention for durable quote reconciliation after billing-node outages.";
      };

      maxPendingQuotesPerSource = lib.mkOption {
        type = lib.types.ints.positive;
        default = 5;
        description = "Maximum simultaneous unpaid payment quotes per source address.";
      };

      claimPollSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 2;
        description = "Browser polling interval advertised by the payment claim endpoint.";
      };

      watchTimeoutSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 30;
        description = "Duration of each billing-node waitanyinvoice request.";
      };

      billingNodeId = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Compressed public key of the dedicated CLN billing node.";
      };

      billingNodeAddress = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "billing.example.com:9735";
        description = "Lightning peer address used for direct BOLT-8 Commando billing RPC.";
      };
    };

    tor = {
      enable = lib.mkEnableOption "connections to v3 onion-service node addresses through SOCKS5";

      manageService = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run a local Tor client and configure its dedicated onion-only SOCKS listener.";
      };

      socksAddress = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "IP address of the Tor SOCKS5 listener used by the relay.";
      };

      socksPort = lib.mkOption {
        type = lib.types.port;
        default = 9050;
        description = "Port of the Tor SOCKS5 listener used by the relay.";
      };
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
        {
          assertion = !cfg.payments.enable || cfg.payments.billingNodeId != null;
          message = "services.zaptunnel-relay.payments.billingNodeId is required when payments are enabled";
        }
        {
          assertion = !cfg.payments.enable || cfg.payments.billingNodeAddress != null;
          message = "services.zaptunnel-relay.payments.billingNodeAddress is required when payments are enabled";
        }
        {
          assertion = !cfg.payments.enable || cfg.environmentFile != null;
          message = "payments require environmentFile containing ZAPTUNNEL_BILLING_NODE_RUNE and ZAPTUNNEL_PAYMENT_TOKEN_SECRET";
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
            ZAPTUNNEL_DRAIN_TIMEOUT_MS = toString (cfg.drainTimeoutSeconds * 1000);
          }
          // lib.optionalAttrs cfg.tls.enable {
            ZAPTUNNEL_TLS_CERTFILE = certificateFile;
            ZAPTUNNEL_TLS_KEYFILE = privateKeyFile;
          }
          // lib.optionalAttrs (cfg.websiteHost != null) {
            ZAPTUNNEL_WEBSITE_HOST = cfg.websiteHost;
          }
          // lib.optionalAttrs (cfg.relayHost != null) {
            ZAPTUNNEL_RELAY_HOST = cfg.relayHost;
          }
          // lib.optionalAttrs cfg.tor.enable {
            ZAPTUNNEL_TOR_SOCKS_ADDRESS = cfg.tor.socksAddress;
            ZAPTUNNEL_TOR_SOCKS_PORT = toString cfg.tor.socksPort;
          }
          // lib.optionalAttrs cfg.payments.enable {
            ZAPTUNNEL_PAYMENTS_ENABLED = "true";
            ZAPTUNNEL_PAYMENT_PRICE_SATS = toString cfg.payments.priceSats;
            ZAPTUNNEL_PAYMENT_NETWORK = cfg.payments.network;
            ZAPTUNNEL_PAYMENT_QUOTE_TTL_MS = toString (cfg.payments.quoteTtlSeconds * 1000);
            ZAPTUNNEL_PAYMENT_LEASE_TTL_MS = toString (cfg.payments.leaseTtlSeconds * 1000);
            ZAPTUNNEL_PAYMENT_CLAIM_GRACE_MS = toString (cfg.payments.claimGraceSeconds * 1000);
            ZAPTUNNEL_PAYMENT_QUOTE_RETENTION_MS = toString (cfg.payments.quoteRetentionSeconds * 1000);
            ZAPTUNNEL_PAYMENT_MAX_PENDING_QUOTES_PER_SOURCE = toString cfg.payments.maxPendingQuotesPerSource;
            ZAPTUNNEL_PAYMENT_CLAIM_POLL_MS = toString (cfg.payments.claimPollSeconds * 1000);
            ZAPTUNNEL_PAYMENT_WATCH_TIMEOUT_SECONDS = toString cfg.payments.watchTimeoutSeconds;
            ZAPTUNNEL_PAYMENT_STATE_PATH = "/var/lib/zaptunnel-relay/payments.dets";
            ZAPTUNNEL_BILLING_NODE_ID = cfg.payments.billingNodeId;
            ZAPTUNNEL_BILLING_NODE_ADDRESS = cfg.payments.billingNodeAddress;
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
            TimeoutStopSec = "${toString (cfg.drainTimeoutSeconds + 10)}s";
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
            ProtectProc = "invisible";
            ProtectSystem = "strict";
            RemoveIPC = true;
            RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
            RestrictNamespaces = true;
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            SystemCallArchitectures = "native";
            SystemCallFilter = ["@system-service" "~@privileged"];
          }
          // cfg.extraServiceConfig;
      };
    }

    (lib.mkIf cfg.tor.enable {
      systemd.services.zaptunnel-relay = {
        after = lib.optional cfg.tor.manageService "tor.service";
        wants = lib.optional cfg.tor.manageService "tor.service";
      };
    })

    (lib.mkIf (cfg.tor.enable && cfg.tor.manageService) {
      services.tor = {
        enable = true;
        client = {
          enable = true;
          socksListenAddress = {
            addr = cfg.tor.socksAddress;
            port = cfg.tor.socksPort;
            IsolateDestAddr = true;
            IsolateDestPort = true;
            OnionTrafficOnly = true;
          };
        };
      };
    })

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
