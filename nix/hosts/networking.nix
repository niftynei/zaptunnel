{ lib, ... }: {
  # This file was populated at runtime with the networking
  # details gathered from the active system.
  networking = {
    nameservers = [ "8.8.8.8"
 ];
    defaultGateway = "159.65.160.1";
    defaultGateway6 = {
      address = "2604:a880:800:14::1";
      interface = "eth0";
    };
    dhcpcd.enable = false;
    usePredictableInterfaceNames = lib.mkForce false;
    interfaces = {
      eth0 = {
        ipv4.addresses = [
          { address="159.65.174.5"; prefixLength=20; }
{ address="10.17.0.7"; prefixLength=16; }
        ];
        ipv6.addresses = [
          { address="2604:a880:800:14:0:3:5efc:e000"; prefixLength=64; }
{ address="fe80::785f:59ff:fe5e:e45d"; prefixLength=64; }
        ];
        ipv4.routes = [ { address = "159.65.160.1"; prefixLength = 32; } ];
        ipv6.routes = [ { address = "2604:a880:800:14::1"; prefixLength = 128; } ];
      };
            eth1 = {
        ipv4.addresses = [
          { address="10.132.0.4"; prefixLength=16; }
        ];
        ipv6.addresses = [
          { address="fe80::1879:bdff:fed7:523f"; prefixLength=64; }
        ];
        };
    };
  };
  services.udev.extraRules = ''
    ATTR{address}=="7a:5f:59:5e:e4:5d", NAME="eth0"
    ATTR{address}=="1a:79:bd:d7:52:3f", NAME="eth1"
  '';
}
