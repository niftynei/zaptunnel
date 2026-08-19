{pkgs, ...}: {
  imports = [
    ./hardware-configuration.nix
    ./networking.nix
  ];

  boot.loader.grub = {
    enable = true;
    device = "/dev/vda";
  };
  boot.tmp.cleanOnBoot = true;

  # DigitalOcean images keep the GRUB configuration and kernels on an ext4
  # Linux extended boot partition. nixos-generate-config omits it because the
  # GPT auto-generator mounts it, so declare it explicitly for deterministic
  # activation and boot behavior.
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/BOOT";
    fsType = "ext4";
  };

  networking = {
    hostName = "zapptunnel";
    firewall.allowedTCPPorts = [22 443];
  };

  time.timeZone = "America/Chicago";

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  # Keep the provisioning key declarative so the first NixOS activation
  # cannot remove the only working route back into the host.
  users.users.root.openssh.authorizedKeys.keyFiles = [
    ./zapptunnel-deploy.pub
  ];

  services.zaptunnel-relay = {
    enable = true;
    openFirewall = true;
    tor.enable = true;
    websiteHost = "zapptunnel.com";
    relayHost = "relay.zapptunnel.com";

    tls = {
      enable = true;
      domain = "zapptunnel.com";

      acme = {
        enable = true;
        email = "niftynei+zaptunnel@gmail.com";
        dnsProvider = "digitalocean";
        credentialFiles = {
          DO_AUTH_TOKEN_FILE = "/var/lib/zapptunnel-secrets/digitalocean-dns-token";
        };
      };
    };
  };

  # The token file is installed out-of-band. The directory is declarative,
  # while the secret remains outside both Git and the Nix store.
  systemd.tmpfiles.rules = [
    "d /var/lib/zapptunnel-secrets 0700 root root - -"
  ];

  services.prometheus = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = 9090;
    retentionTime = "30d";
    ruleFiles = [../alerts/zaptunnel.yml];
    alertmanagers = [
      {
        static_configs = [
          {targets = ["127.0.0.1:9093"];}
        ];
      }
    ];

    exporters.node = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 9100;
      enabledCollectors = ["systemd"];
    };

    scrapeConfigs = [
      {
        job_name = "zapptunnel";
        scheme = "https";
        metrics_path = "/metrics";
        static_configs = [
          {targets = ["127.0.0.1:443"];}
        ];
        tls_config.server_name = "relay.zapptunnel.com";
      }
      {
        job_name = "node";
        static_configs = [
          {targets = ["127.0.0.1:9100"];}
        ];
      }
      {
        job_name = "prometheus";
        static_configs = [
          {targets = ["127.0.0.1:9090"];}
        ];
      }
    ];
  };

  services.prometheus.alertmanager = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = 9093;
    configuration = {
      global.resolve_timeout = "5m";
      route = {
        receiver = "journal";
        group_by = ["alertname" "severity"];
        group_wait = "30s";
        group_interval = "5m";
        repeat_interval = "4h";
      };
      receivers = [
        {
          name = "journal";
          webhook_configs = [
            {
              url = "http://127.0.0.1:6725";
              send_resolved = true;
            }
          ];
        }
      ];
    };
  };

  services.prometheus.alertmanagerWebhookLogger.enable = true;

  # Grafana is deliberately private, just like Prometheus. Operators reach it
  # through the SSH tunnel exposed by `make grafana`; no additional public
  # firewall port or reverse proxy is required.
  services.grafana = {
    enable = true;

    settings = {
      server = {
        http_addr = "127.0.0.1";
        http_port = 3000;
      };

      analytics = {
        reporting_enabled = false;
        check_for_updates = false;
        check_for_plugin_updates = false;
        feedback_links_enabled = false;
      };

      "auth.anonymous" = {
        enabled = false;
      };

      auth.disable_login_form = false;
      security = {
        admin_user = "admin";
        admin_password = "$__file{/var/lib/grafana/admin_password}";
        disable_initial_admin_creation = false;
        secret_key = "$__file{/var/lib/grafana/secret_key}";
      };
      users.default_theme = "dark";
      dashboards.default_home_dashboard_path = toString ../dashboards/zaptunnel.json;
    };

    provision = {
      enable = true;

      datasources.settings = {
        apiVersion = 1;
        prune = true;
        datasources = [
          {
            name = "Prometheus";
            uid = "prometheus";
            type = "prometheus";
            access = "proxy";
            url = "http://127.0.0.1:9090";
            isDefault = true;
            editable = false;
          }
        ];
      };

      dashboards.settings = {
        apiVersion = 1;
        providers = [
          {
            name = "Zaptunnel";
            folder = "Zaptunnel";
            type = "file";
            disableDeletion = true;
            editable = false;
            options.path = ../dashboards;
          }
        ];
      };
    };
  };

  # Grafana 12 requires an installation-specific encryption key. Generate it
  # once as the unprivileged service user and keep it outside the Nix store.
  systemd.services.grafana.preStart = ''
    umask 077
    if [ ! -s /var/lib/grafana/secret_key ]; then
      ${pkgs.openssl}/bin/openssl rand -hex 32 > /var/lib/grafana/secret_key
    fi
    if [ ! -s /var/lib/grafana/admin_password ]; then
      ${pkgs.openssl}/bin/openssl rand -base64 24 > /var/lib/grafana/admin_password
    fi
  '';

  environment.systemPackages = with pkgs; [
    htop
    tmux
  ];

  nix.settings = {
    experimental-features = ["nix-command" "flakes"];
    auto-optimise-store = true;
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  system.stateVersion = "25.05";
}
