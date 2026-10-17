import sys
from pathlib import Path
from unittest.mock import patch

import tiktoken
import tiktoken.load

with patch.object(
    tiktoken.load, "read_file", side_effect=AssertionError("unexpected tokenizer download")
):
    for name in ("o200k_base", "cl100k_base"):
        encoding = tiktoken.get_encoding(name)
        assert encoding.decode(encoding.encode("hello")) == "hello"

    from src.main import app
    from src.deriver import __main__
    from src.utils.tokens import estimate_tokens

    assert app.version == sys.argv[1]
    assert "/health" in app.openapi()["paths"]
    assert callable(__main__.run_deriver)
    assert estimate_tokens("hello") == 1

from src import migrate

with patch("src.migrate.command.upgrade") as run_upgrade:
    migrate.upgrade()

config, revision = run_upgrade.call_args.args
assert not Path("alembic.ini").exists()
config_path = Path(config.config_file_name)
assert config_path.is_absolute() and config_path.is_file()
assert config_path.parent == Path(migrate.__file__).resolve().parent.parent
assert (
    Path(config.get_main_option("script_location")) == config_path.parent / "migrations"
)
assert (config_path.parent / "migrations" / "env.py").is_file()
assert revision == "head"
