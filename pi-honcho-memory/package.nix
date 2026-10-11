{
  lib,
  stdenvNoCC,
  fetchurl,
  jq,
  src,
}:

let
  honchoSdk = fetchurl {
    url = "https://registry.npmjs.org/@honcho-ai/sdk/-/sdk-2.0.1.tgz";
    hash = "sha512-y/Wk49C0N1miI9BZTNWFIbzdUkMZfP4Do/EJ1q4lEIK+FAOKxQgces/zET3kPKV3zF9sOUl2pXrFb/XKYayeYw==";
  };
  zod = fetchurl {
    url = "https://registry.npmjs.org/zod/-/zod-4.0.0.tgz";
    hash = "sha512-9diLdTPc/L7w/5jI4C3gHYNiGHDV9IZYxo1e5LSD8cabi65WVTWWb+g2BGPEpUUCOxR4D+6O5B0AzyMdUAXwrw==";
  };
in
stdenvNoCC.mkDerivation {
  pname = "pi-honcho-memory";
  version = (builtins.fromJSON (builtins.readFile (src + "/package.json"))).version;
  inherit src;

  nativeBuildInputs = [ jq ];
  dontBuild = true;

  patches = [ ./lifecycle.patch ];

  postPatch = ''
    substituteInPlace extensions/{client,commands,git,index,session-key,tools}.ts \
      --replace-fail '@mariozechner/pi-coding-agent' '@earendil-works/pi-coding-agent'
    substituteInPlace extensions/tools.ts \
      --replace-fail '@mariozechner/pi-ai' '@earendil-works/pi-ai' \
      --replace-fail '@sinclair/typebox' 'typebox'
    substituteInPlace package.json \
      --replace-fail '@mariozechner/pi-coding-agent' '@earendil-works/pi-coding-agent' \
      --replace-fail '@mariozechner/pi-ai' '@earendil-works/pi-ai' \
      --replace-fail '@sinclair/typebox' 'typebox'
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/extensions $out/node_modules/@honcho-ai/sdk $out/node_modules/zod
    jq '.pi.extensions = ["./extensions/index.ts"] | del(.devDependencies, .scripts, .packageManager)' \
      package.json > $out/package.json
    cp extensions/*.ts $out/extensions/
    cp LICENSE $out/

    tar -xzf ${honchoSdk} -C $out/node_modules/@honcho-ai/sdk --strip-components=1
    tar -xzf ${zod} -C $out/node_modules/zod --strip-components=1

    runHook postInstall
  '';

  meta = {
    description = "Honcho persistent memory extension for Pi";
    homepage = "https://github.com/agneym/pi-honcho-memory";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
}
