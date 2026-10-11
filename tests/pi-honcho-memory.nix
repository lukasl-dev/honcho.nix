{
  pkgs,
  pi,
  extension,
}:

let
  entry = "${extension}/extensions/index.ts";
  configured = pi.lib.mkCodingAgent {
    inherit pkgs;
    modules = [ { pi.coding-agent.extensions = [ entry ]; } ];
  };
in
assert pkgs.lib.elem entry configured.args;
pkgs.runCommand "pi-honcho-memory-check"
  {
    nativeBuildInputs = [ pkgs.nodejs_24 ];
  }
  ''
    export HOME="$TMPDIR/home"
    export PI_CODING_AGENT_DIR="$HOME/.pi/agent"
    mkdir -p "$HOME" "$PI_CODING_AGENT_DIR"
    node ${./pi-honcho-memory.mjs} \
      ${pi.packages.${pkgs.stdenv.hostPlatform.system}.coding-agent}/lib/node_modules \
      ${extension}
    touch $out
  ''
