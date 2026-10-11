{ pkgs, self }:

let
  inherit (pkgs) lib;
  evaluate =
    settings:
    (self.inputs.nixpkgs.lib.nixosSystem {
      system = pkgs.stdenv.hostPlatform.system;
      modules = [
        self.nixosModules.default
        {
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "/dev/vda";
            fsType = "ext4";
          };
          system.stateVersion = "26.05";
          services.honcho = settings;
        }
      ];
    }).config;

  disabled = evaluate { };
  local = evaluate { enable = true; };
  external = evaluate {
    enable = true;
    database.createLocally = false;
    database.migrate = false;
    worker.enable = false;
    host = "0.0.0.0";
    port = 18000;
    openFirewall = true;
    environmentFile = "/run/secrets/honcho.env";
  };
  invalidSecret = evaluate {
    enable = true;
    environmentFile = "${pkgs.writeText "not-a-runtime-secret" "synthetic"}";
  };
in
assert !disabled.services.postgresql.enable;
assert !(disabled.systemd.services ? honcho);

assert local.services.postgresql.enable;
assert local.users.users.honcho.group == "honcho";
assert local.services.honcho.settings.auth.USE_AUTH;
assert local.networking.firewall.allowedTCPPorts == [ ];
assert lib.elem "honcho-migrate.service" local.systemd.services.honcho.requires;
assert lib.elem "postgresql-setup.service" local.systemd.services.honcho-database.after;
assert lib.elem "postgresql-setup.service" local.systemd.services.honcho-database.requires;
assert local.systemd.services.honcho-worker.serviceConfig.Restart == "always";

assert !external.services.postgresql.enable;
assert !(external.systemd.services ? honcho-database);
assert !(external.systemd.services ? honcho-migrate);
assert !(external.systemd.services ? honcho-worker);
assert external.networking.firewall.allowedTCPPorts == [ 18000 ];
assert
  external.systemd.services.honcho.serviceConfig.EnvironmentFile == [ "/run/secrets/honcho.env" ];
assert lib.any (a: !a.assertion) invalidSecret.assertions;
pkgs.runCommand "honcho-module-check" { } ''
  touch $out
''
