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
      # These upstream CLI releases left __version__ behind the package metadata.
      honcho-cli = prev.honcho-cli.overrideAttrs (
        old:
        let
          reportedVersion =
            {
              "0.2.1" = "0.2.0";
              "0.5.0" = "0.4.0";
            }
            .${old.version} or null;
        in
        lib.optionalAttrs (reportedVersion != null) {
          postPatch = (old.postPatch or "") + ''
            substituteInPlace src/honcho_cli/__init__.py \
              --replace-fail '__version__ = "${reportedVersion}"' '__version__ = "${old.version}"'
          '';
        }
      );
    })
  ]
)
