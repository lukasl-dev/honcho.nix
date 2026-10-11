{
  description = "Honcho packaged for Nix";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    honcho = {
      url = "github:plastic-labs/honcho/v3.2.2";
      flake = false;
    };

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs = {
        pyproject-nix.follows = "pyproject-nix";
        uv2nix.follows = "uv2nix";
        nixpkgs.follows = "nixpkgs";
      };
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "aarch64-linux"
        "x86_64-linux"
      ];

      perSystem =
        { pkgs, self', ... }:
        let
          pythonSet = pkgs.callPackage ./python.nix {
            src = inputs.honcho;
            inherit (inputs) uv2nix pyproject-nix pyproject-build-systems;
          };
        in
        {
          packages = rec {
            default = honcho;
            honcho = pkgs.callPackage ./honcho/package.nix {
              src = inputs.honcho;
              inherit pythonSet;
            };
            honcho-cli = pkgs.callPackage ./honcho-cli/package.nix {
              src = inputs.honcho;
              inherit pythonSet;
            };

            docs-md =
              let
                instance = inputs.nixpkgs.lib.nixosSystem {
                  system = pkgs.stdenv.hostPlatform.system;
                  modules = [ inputs.self.nixosModules.default ];
                };
                docs = pkgs.nixosOptionsDoc {
                  options.services.honcho = instance.options.services.honcho;
                };
              in
              pkgs.runCommand "honcho-options.md" { } ''
                mkdir -p $out
                cp ${docs.optionsCommonMark} $out/index.md
              '';
          };

          checks = {
            cli-unit =
              pkgs.runCommand "honcho-cli-unit-tests"
                {
                  nativeBuildInputs = [
                    (pythonSet.mkVirtualEnv "honcho-cli-test-env" { honcho-cli = [ "dev" ]; })
                  ];
                }
                ''
                  export HOME="$TMPDIR/home"
                  export HONCHO_CONFIG_DIR="$HOME/.honcho"
                  export HONCHO_NO_UPDATE_CHECK=1
                  mkdir -p "$HOME"
                  cp -R ${inputs.honcho}/honcho-cli/tests tests
                  chmod -R u+w tests
                  cd tests
                  pytest -q test_config.py test_common.py test_output.py test_validation.py \
                    test_recall.py test_local.py test_commands.py
                  touch $out
                '';
            cli =
              pkgs.runCommand "honcho-cli-check"
                {
                  nativeBuildInputs = [ self'.packages.honcho-cli ];
                }
                ''
                  export HOME="$TMPDIR/home"
                  export HONCHO_CONFIG_DIR="$HOME/.honcho"
                  export HONCHO_NO_UPDATE_CHECK=1
                  mkdir -p "$HOME"

                  honcho --version | grep -F 'honcho-cli ${self'.packages.honcho-cli.version}'
                  honcho workspace --help | grep -F 'workspaces'
                  ${self'.packages.honcho-cli.pythonEnv}/bin/python ${./tests/cli.py} \
                    ${self'.packages.honcho-cli.version} \
                    ${pythonSet.honcho-ai.version}
                  touch $out
                '';
            combined = pkgs.buildEnv {
              name = "honcho-server-and-cli";
              paths = [
                self'.packages.honcho
                self'.packages.honcho-cli
              ];
              pathsToLink = [ "/bin" ];
            };
            module = import ./honcho/module-tests.nix {
              inherit pkgs;
              self = inputs.self;
            };
            service = import ./tests/service.nix {
              inherit pkgs;
              self = inputs.self;
            };
            package =
              pkgs.runCommand "honcho-package-check"
                {
                  nativeBuildInputs = [ self'.packages.honcho ];
                  PYTHONPATH = "${self'.packages.honcho}/share/honcho";
                  TIKTOKEN_CACHE_DIR = self'.packages.honcho.tokenCache;
                  PYTHON_DOTENV_DISABLED = "1";
                  HONCHO_CONFIG_TOML_DISABLED = "1";
                  PYTHONDONTWRITEBYTECODE = "1";
                  AUTH_USE_AUTH = "true";
                  AUTH_JWT_SECRET = "synthetic-package-check-signing-secret";
                }
                ''
                  export HOME="$TMPDIR/home"
                  mkdir -p "$HOME"
                  ${self'.packages.honcho.pythonEnv}/bin/python ${./tests/package.py} ${self'.packages.honcho.version}
                  honcho-server --help >/dev/null
                  honcho-token --admin --expires 1h --print-only >/dev/null
                  honcho-configure-embeddings --help >/dev/null
                  touch $out
                '';
          };

          devShells.default = pkgs.mkShell {
            packages = [
              pkgs.nixfmt
              pkgs.actionlint
              pkgs.basedpyright
              pkgs.uv
              pkgs.gh
            ];
          };

          formatter = pkgs.nixfmt;

          apps = {
            update = {
              type = "app";
              program = "${import ./update.nix { inherit pkgs; }}/bin/honcho-update";
              meta.description = "Update the pinned Honcho release";
            };
          };
        };

      flake = {
        nixosModules = rec {
          default = honcho;
          honcho = import ./honcho/module.nix { self = inputs.self; };
        };

        overlays.default = _final: prev: {
          honcho = inputs.self.packages.${prev.stdenv.hostPlatform.system}.honcho;
          honcho-cli = inputs.self.packages.${prev.stdenv.hostPlatform.system}.honcho-cli;
        };
      };
    };
}
