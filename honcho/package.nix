{
  lib,
  stdenvNoCC,
  makeWrapper,
  fetchurl,
  linkFarm,
  src,
  pythonSet,
  extras ? [ ],
}:

let
  pythonEnv = pythonSet.mkVirtualEnv "honcho-python-env" { honcho = extras; };

  # tiktoken names cached encodings by SHA-1 of their download URL.
  tokenCache = linkFarm "honcho-tiktoken-cache" [
    {
      name = "fb374d419588a4632f3f557e76b4b70aebbca790";
      path = fetchurl {
        url = "https://openaipublic.blob.core.windows.net/encodings/o200k_base.tiktoken";
        hash = "sha256-RGqVOMtsNI41FhINfAiwn1fDZJXirP/+WaW/iwz7Gi0=";
      };
    }
    {
      name = "9b5ad71b2ce5302211f9c61530b329a4922fc6a4";
      path = fetchurl {
        url = "https://openaipublic.blob.core.windows.net/encodings/cl100k_base.tiktoken";
        hash = "sha256-Ijkht27pm96ZW3/3OFE+7xAPtR0YyTWXoRO8/+hlsqc=";
      };
    }
  ];
in
stdenvNoCC.mkDerivation {
  pname = "honcho";
  version = (builtins.fromTOML (builtins.readFile (src + "/pyproject.toml"))).project.version;
  inherit src;

  nativeBuildInputs = [ makeWrapper ];
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/honcho $out/bin
    cp -R src migrations scripts alembic.ini pyproject.toml LICENSE $out/share/honcho/

    substituteInPlace $out/share/honcho/src/db.py \
      --replace-fail 'Config("alembic.ini")' 'Config("'"$out"'/share/honcho/alembic.ini")'
    substituteInPlace $out/share/honcho/alembic.ini \
      --replace-fail 'script_location = migrations' 'script_location = %(here)s/migrations'

    wrapperArgs=(
      --prefix PYTHONPATH : "$out/share/honcho"
      --set-default TIKTOKEN_CACHE_DIR ${tokenCache}
      --set-default PYTHONDONTWRITEBYTECODE 1
    )

    makeWrapper ${pythonEnv}/bin/uvicorn $out/bin/honcho-server "''${wrapperArgs[@]}" \
      --add-flags "src.main:app"
    makeWrapper ${pythonEnv}/bin/python $out/bin/honcho-worker "''${wrapperArgs[@]}" \
      --add-flags "-m src.deriver"
    makeWrapper ${pythonEnv}/bin/python $out/bin/honcho-migrate "''${wrapperArgs[@]}" \
      --add-flags "$out/share/honcho/scripts/provision_db.py"
    makeWrapper ${pythonEnv}/bin/python $out/bin/honcho-token "''${wrapperArgs[@]}" \
      --add-flags "$out/share/honcho/scripts/generate_jwt.py"
    makeWrapper ${pythonEnv}/bin/python $out/bin/honcho-configure-embeddings "''${wrapperArgs[@]}" \
      --add-flags "$out/share/honcho/scripts/configure_embeddings.py"

    runHook postInstall
  '';

  passthru = { inherit pythonEnv tokenCache; };

  meta = {
    description = "Memory and reasoning API for AI agents";
    homepage = "https://github.com/plastic-labs/honcho";
    license = lib.licenses.agpl3Only;
    mainProgram = "honcho-server";
    platforms = lib.platforms.linux;
  };
}
