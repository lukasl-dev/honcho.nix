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

      perSystem = { pkgs, self', ... }: {
        packages = rec {
          default = honcho;
          honcho = pkgs.callPackage ./package.nix {
            src = inputs.honcho;
            inherit (inputs) uv2nix pyproject-nix pyproject-build-systems;
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
          module = import ./tests/module.nix {
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
                honcho --help >/dev/null
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
          honcho = import ./module.nix { self = inputs.self; };
        };

        overlays.default = _final: prev: {
          honcho = inputs.self.packages.${prev.stdenv.hostPlatform.system}.honcho;
        };
      };
    };
}
