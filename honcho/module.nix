{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.honcho;
  toml = pkgs.formats.toml { };
  settingsFile = toml.generate "honcho-config.toml" cfg.settings;
  databaseServices = lib.optional cfg.database.createLocally "honcho-database.service";
  migrationServices = lib.optional cfg.database.migrate "honcho-migrate.service";

  common = {
    after = [ "network-online.target" ] ++ databaseServices;
    wants = [ "network-online.target" ];
    requires = databaseServices;
    restartTriggers = [ settingsFile ];

    environment = {
      HOME = cfg.dataDir;
      PYTHON_DOTENV_DISABLED = "1";
      PYTHONDONTWRITEBYTECODE = "1";
    }
    // cfg.environment;

    serviceConfig = {
      User = "honcho";
      Group = "honcho";
      WorkingDirectory = cfg.dataDir;
      EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile;
      UMask = "0077";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [ cfg.dataDir ];
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
    };
  };
in
{
  options.services.honcho = {
    enable = lib.mkEnableOption "the Honcho memory API and background worker";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.honcho;
      defaultText = lib.literalExpression "honcho.packages.\${pkgs.stdenv.hostPlatform.system}.honcho";
      description = "Honcho package to run.";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "API listen address.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8000;
      description = "API listen port.";
    };

    workers = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = "Number of API worker processes.";
    };

    worker.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run Honcho's background derivation, dream and reconciliation worker.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/honcho";
      description = "Working directory for generated configuration and optional local storage.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the API port in the NixOS firewall.";
    };

    settings = lib.mkOption {
      inherit (toml) type;
      default = { };
      description = ''
        Honcho config.toml settings, using upstream section and field names.
        Environment variables override these values. Do not put secrets here:
        the generated configuration is readable in the Nix store.
      '';
      example = lib.literalExpression ''
        {
          deriver.MODEL_CONFIG = {
            transport = "openai";
            model = "gpt-5.4-mini";
          };
          cache.ENABLED = false;
        }
      '';
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Non-secret environment variables shared by the API, worker and migrations.";
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/secrets/honcho.env";
      description = ''
        Runtime systemd EnvironmentFile containing credentials such as
        AUTH_JWT_SECRET, LLM_OPENAI_API_KEY and an external DB_CONNECTION_URI.
        Use an absolute path outside the Nix store; systemd reads it as root.
      '';
    };

    database = {
      createLocally = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Create a local PostgreSQL database and role named honcho, install
          pgvector, and connect over the Unix socket using peer authentication.
          Disable this and supply DB_CONNECTION_URI for an external database.
          External databases must already have the vector extension installed.
        '';
      };

      migrate = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run upstream database migrations before starting the API and worker.";
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = lib.hasPrefix "/" cfg.dataDir && cfg.dataDir != "/";
            message = "services.honcho.dataDir must be an absolute directory other than /.";
          }
          {
            assertion =
              cfg.environmentFile == null
              || (lib.hasPrefix "/" cfg.environmentFile && !lib.hasPrefix builtins.storeDir cfg.environmentFile);
            message = "services.honcho.environmentFile must be an absolute runtime path outside the Nix store.";
          }
        ];

        services.honcho.settings = {
          auth.USE_AUTH = lib.mkDefault true;
          metrics.ENABLED = lib.mkDefault false;
          sentry.ENABLED = lib.mkDefault false;
          telemetry.ENABLED = lib.mkDefault false;
        };

        environment.systemPackages = [ cfg.package ];
        networking.firewall.allowedTCPPorts = lib.optional cfg.openFirewall cfg.port;

        users.groups.honcho = { };
        users.users.honcho = {
          isSystemUser = true;
          group = "honcho";
          home = cfg.dataDir;
        };

        systemd.tmpfiles.rules = [
          "d ${cfg.dataDir} 0700 honcho honcho -"
          "L+ ${cfg.dataDir}/config.toml - - - - ${settingsFile}"
        ];

        systemd.services.honcho = lib.recursiveUpdate common {
          description = "Honcho memory API";
          wantedBy = [ "multi-user.target" ];
          after = common.after ++ migrationServices;
          requires = common.requires ++ migrationServices;
          serviceConfig = {
            ExecStart = lib.escapeShellArgs [
              (lib.getExe cfg.package)
              "--host"
              cfg.host
              "--port"
              (toString cfg.port)
              "--workers"
              (toString cfg.workers)
            ];
            Restart = "on-failure";
            RestartSec = 5;
          };
        };
      }

      (lib.mkIf cfg.worker.enable {
        systemd.services.honcho-worker = lib.recursiveUpdate common {
          description = "Honcho background worker";
          wantedBy = [ "multi-user.target" ];
          after = common.after ++ migrationServices;
          requires = common.requires ++ migrationServices;
          serviceConfig = {
            ExecStart = "${cfg.package}/bin/honcho-worker";
            Restart = "always";
            RestartSec = 5;
          };
        };
      })

      (lib.mkIf cfg.database.migrate {
        systemd.services.honcho-migrate = lib.recursiveUpdate common {
          description = "Migrate the Honcho database";
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${cfg.package}/bin/honcho-migrate";
          };
        };
      })

      (lib.mkIf cfg.database.createLocally {
        services.honcho.settings.db.CONNECTION_URI =
          lib.mkDefault "postgresql+psycopg://honcho@/honcho?host=/run/postgresql";

        services.postgresql = {
          enable = true;
          extensions = ps: [ ps.pgvector ];
          ensureDatabases = [ "honcho" ];
          ensureUsers = [
            {
              name = "honcho";
              ensureDBOwnership = true;
            }
          ];
        };

        systemd.services.honcho-database = {
          description = "Install pgvector in the Honcho database";
          after = [
            "postgresql.service"
            "postgresql-setup.service"
          ];
          requires = [
            "postgresql.service"
            "postgresql-setup.service"
          ];
          serviceConfig = {
            Type = "oneshot";
            User = "postgres";
            RemainAfterExit = true;
            ExecStart = "${config.services.postgresql.package}/bin/psql --dbname honcho --command 'CREATE EXTENSION IF NOT EXISTS vector;'";
          };
        };
      })
    ]
  );
}
