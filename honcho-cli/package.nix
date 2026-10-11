{
  lib,
  stdenvNoCC,
  src,
  pythonSet,
}:

let
  version =
    (builtins.fromTOML (builtins.readFile (src + "/honcho-cli/pyproject.toml"))).project.version;
  pythonEnv = pythonSet.mkVirtualEnv "honcho-cli-python-env" { honcho-cli = [ ]; };
in
stdenvNoCC.mkDerivation {
  pname = "honcho-cli";
  inherit version;

  dontUnpack = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    ln -s ${pythonEnv}/bin/honcho $out/bin/honcho

    runHook postInstall
  '';

  passthru = { inherit pythonEnv; };

  meta = {
    description = "Command-line interface for Honcho memory";
    homepage = "https://honcho.dev/docs/v3/documentation/reference/cli";
    license = lib.licenses.mit;
    mainProgram = "honcho";
    platforms = lib.platforms.linux;
  };
}
