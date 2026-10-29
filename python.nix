{
  lib,
  callPackage,
  python313,
  src,
  uv2nix,
  pyproject-nix,
  pyproject-build-systems,
}:

let
  workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = src; };
in
(callPackage pyproject-nix.build.packages { python = python313; }).overrideScope (
  lib.composeManyExtensions [
    pyproject-build-systems.overlays.wheel
    (workspace.mkPyprojectOverlay { sourcePreference = "wheel"; })
    (final: prev: {
      # Upstream 0.2.1 still reports 0.2.0 at runtime.
      honcho-cli = prev.honcho-cli.overrideAttrs (
        old:
        lib.optionalAttrs (old.version == "0.2.1") {
          postPatch = (old.postPatch or "") + ''
            substituteInPlace src/honcho_cli/__init__.py \
              --replace-fail '__version__ = "0.2.0"' '__version__ = "0.2.1"'
          '';
        }
      );
    })
  ]
)
