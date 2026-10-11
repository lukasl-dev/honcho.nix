# honcho.nix

Native [Honcho](https://github.com/plastic-labs/honcho) packaging and a NixOS service, using upstream's uv lockfile.

```sh
nix build
nix run -- --help
nix run .#honcho-cli -- --help
nix develop
nix flake check
nix run .#update
nix build .#docs-md
```

## NixOS

`honcho` packages the server (`honcho-server`); `honcho-cli` provides the upstream `honcho` client command. Both use the pinned upstream workspace and lockfile.

The CLI reads `HONCHO_BASE_URL`, `HONCHO_API_KEY` (a client JWT) and optional `HONCHO_WORKSPACE_ID`. Its Docker stack commands still require Docker/Compose; they are separate from the native NixOS service.

Add `honcho.url = "github:lukasl-dev/honcho.nix";` to your flake inputs:

```nix
{
  imports = [ inputs.honcho.nixosModules.default ];

  services.honcho = {
    enable = true;
    environmentFile = "/run/secrets/honcho.env";
  };
}
```

Provide `AUTH_JWT_SECRET` and model-provider credentials in the root-readable runtime environment file, never in the Nix store. Upstream's current defaults use `LLM_OPENAI_API_KEY`.

The service listens on `127.0.0.1:8000`, with authentication enabled and the firewall closed. Local PostgreSQL/pgvector, migrations and the background worker are managed automatically. Use `settings` for upstream [config.toml](https://github.com/plastic-labs/honcho/blob/main/config.toml.example) options; `nix build .#docs-md` generates the NixOS option reference.

Clients use signed JWTs, not the signing secret. With `AUTH_JWT_SECRET` securely exported:

```sh
honcho-token --admin --expires 1h --print-only
honcho-token --workspace my-workspace --expires 30d --print-only
```

For external PostgreSQL, set `database.createLocally = false` and supply `DB_CONNECTION_URI=postgresql+psycopg://…`; pgvector must already be installed. Set `database.migrate = false` when migrations are managed elsewhere.

Back up before upgrades. Changing existing embedding models/dimensions requires explicit schema/re-embedding work with `honcho-configure-embeddings`, not just new settings. Use HTTPS and retain authentication when exposing the API.

The daily GitHub cron builds and tests stable Honcho release updates before committing and tagging them.

## Pi memory extension

```nix
pi.coding-agent.extensions = [
  "${inputs.honcho.packages.${pkgs.stdenv.hostPlatform.system}.pi-honcho-memory}/extensions/index.ts"
];
pi.coding-agent.environment = {
  HONCHO_URL.value = "http://127.0.0.1:8000";
  HONCHO_API_KEY.file = "/run/secrets/honcho-client-jwt";
  HONCHO_WORKSPACE_ID.value = "default";
};
```

The API key must be a client JWT, not the server's signing key. The extension also reads `~/.honcho/config.json`; its URL variable is `HONCHO_URL`, not the CLI's `HONCHO_BASE_URL`.
