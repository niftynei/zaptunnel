{ lib, ... }: {
  # This file was populated at runtime with the networking
  # details gathered from the active system.
  networking = {
    nameservers = [ "8.8.8.8"
 ];
    defaultGateway = "159.203.80.1";
    defaultGateway6 = {
      address = "2604:a880:800:14::1";
      interface = "eth0";
    };
    dhcpcd.enable = false;
    usePredictableInterfaceNames = lib.mkForce false;
    interfaces = {
      eth0 = {
        ipv4.addresses = [
          { address="159.203.87.45"; prefixLength=20; }
{ address="10.17.0.7"; prefixLength=16; }
        ];
        ipv6.addresses = [
          { address="2604:a880:800:14:0:3:5ef3:b000"; prefixLength=64; }
{ address="fe80::540d:eff:fecd:387d"; prefixLength=64; }
        ];
        ipv4.routes = [ { address = "159.203.80.1"; prefixLength = 32; } ];
        ipv6.routes = [ { address = "2604:a880:800:14::1"; prefixLength = 128; } ];
      };
            eth1 = {
        ipv4.addresses = [
          { address="10.132.0.3"; prefixLength=16; }
        ];
        ipv6.addresses = [
          { address="fe80::3083:f7ff:feea:4f9b"; prefixLength=64; }
        ];
        };
    };
  };
  services.udev.extraRules = ''
    ATTR{address}=="56:0d:0e:cd:38:7d", NAME="eth0"
    ATTR{address}=="32:83:f7:ea:4f:9b", NAME="eth1"
  '';
}
