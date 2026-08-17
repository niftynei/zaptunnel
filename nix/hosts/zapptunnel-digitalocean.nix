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
