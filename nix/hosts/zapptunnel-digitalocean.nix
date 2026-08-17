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

  # Terraform installs the initial root key. Add permanent deployment keys
  # here before relying on this configuration as the only source of access.
  users.users.root.openssh.authorizedKeys.keys = [];

  services.zaptunnel-relay = {
    enable = true;
    openFirewall = true;
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
