# honcho.nix

Native [Honcho](https://github.com/plastic-labs/honcho) packaging and a NixOS service, using upstream's uv lockfile.

```sh
nix build
nix run -- --help
nix develop
nix flake check
nix run .#update
nix build .#docs-md
```

## NixOS

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

The daily GitHub cron builds and tests stable release updates before committing and tagging them.
