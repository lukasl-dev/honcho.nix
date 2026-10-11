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
  ]
)
