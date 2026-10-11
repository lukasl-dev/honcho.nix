{ pkgs, self }:

let
  pyrightConfig = pkgs.writeText "honcho-service-pyright.json" (
    builtins.toJSON {
      typeCheckingMode = "strict";
      pythonVersion = pkgs.python3.pythonVersion;
      extraPaths = [ "${pkgs.path}/nixos/lib/test-driver/src" ];
    }
  );
  test = pkgs.testers.runNixOSTest {
    name = "honcho-service";

    nodes.machine =
      { config, ... }:
      {
        imports = [ self.nixosModules.default ];

        services.honcho = {
          enable = true;
          environmentFile = "/run/honcho-test.env";
          settings = {
            cache.ENABLED = false;
            deriver.POLLING_STARTUP_JITTER_SECONDS = 0.0;
            llm = {
              OPENAI_BASE_URL = "http://127.0.0.1:9/v1";
              ANTHROPIC_BASE_URL = "http://127.0.0.1:9";
              GEMINI_BASE_URL = "http://127.0.0.1:9";
            };
            embedding.MODEL_CONFIG.overrides.base_url = "http://127.0.0.1:9/v1";
          };
          environment.LOG_LEVEL = "DEBUG";
        };

        assertions = [
          {
            assertion = config.services.honcho.settings.auth.USE_AUTH;
            message = "The service test must exercise default JWT authentication.";
          }
          {
            assertion = !(builtins.elem 8000 config.networking.firewall.allowedTCPPorts);
            message = "Honcho must not open the firewall by default.";
          }
        ];

        systemd.services.honcho-test-secrets = {
          before = [ "honcho-migrate.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            UMask = "0077";
          };
          script = ''
            install -m 0600 /dev/null /run/honcho-test.env
            printf '%s\n' \
              'AUTH_JWT_SECRET=honcho-integration-test-jwt-secret' \
              'LLM_OPENAI_API_KEY=honcho-integration-test-dummy-provider-key' \
              > /run/honcho-test.env
          '';
        };
        systemd.services.honcho-migrate = {
          after = [ "honcho-test-secrets.service" ];
          requires = [ "honcho-test-secrets.service" ];
        };

        environment.systemPackages = [ pkgs.curl ];
        virtualisation = {
          memorySize = 4096;
          cores = 2;
          diskSize = 6144;
        };
      };

    nodes.client = {
      environment.systemPackages = [ pkgs.curl ];
      virtualisation.memorySize = 384;
    };

    testScript = builtins.readFile ./service.py;
  };
in
test.overrideTestDerivation (old: {
  buildCommand = ''
    ${pkgs.basedpyright}/bin/basedpyright \
      --warnings \
      --project ${pyrightConfig} \
      --pythonpath ${pkgs.python3.interpreter} \
      ${./service.py}

    ${old.buildCommand}
  '';
})
