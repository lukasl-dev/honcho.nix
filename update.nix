{ pkgs }:

pkgs.writeShellApplication {
  name = "honcho-update";
  runtimeInputs = [
    pkgs.gh
    pkgs.gitMinimal
    pkgs.jq
    pkgs.nix
    pkgs.gnused
  ];
  text = ''
    root="$(git rev-parse --show-toplevel)"
    cd "$root"

    version="''${1:-$(gh api repos/plastic-labs/honcho/releases/latest --jq .tag_name)}"
    if [[ ! "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "Expected a stable Honcho release tag, got: $version" >&2
      exit 1
    fi

    previous="$(jq -r .nodes.honcho.original.ref flake.lock)"
    if [[ "$version" == "$previous" ]]; then
      echo "Honcho is already at $version."
      exit 0
    fi

    sed -i -E \
      "s@github:plastic-labs/honcho/v[0-9]+\.[0-9]+\.[0-9]+@github:plastic-labs/honcho/$version@" \
      flake.nix
    nix flake update honcho

    echo "Updated Honcho to $version. Run nix flake check before committing."
  '';
}
