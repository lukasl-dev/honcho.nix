import json
import os
import sys
from importlib import metadata, resources
from pathlib import Path

from honcho import Honcho
from honcho_cli.config import CLIConfig, CONFIG_FILE

assert metadata.version("honcho-cli") == sys.argv[1]
assert metadata.version("honcho-ai") == sys.argv[2]
assert callable(Honcho)

templates = resources.files("honcho_cli").joinpath("local", "templates")
assert "services:" in templates.joinpath("docker-compose.yml").read_text()
assert "CREATE EXTENSION" in templates.joinpath("init.sql").read_text()

CONFIG_FILE.parent.mkdir(parents=True)
CONFIG_FILE.write_text(json.dumps({"saveMessages": True, "hosts": {"fixture": True}}))

config = CLIConfig(base_url="http://127.0.0.1:8000", api_key="synthetic-cli-key")
config.save()

saved = json.loads(CONFIG_FILE.read_text())
assert saved["environmentUrl"] == config.base_url
assert saved["apiKey"] == config.api_key
assert saved["saveMessages"] is True
assert saved["hosts"] == {"fixture": True}
assert CONFIG_FILE.stat().st_mode & 0o777 == 0o600
assert CONFIG_FILE.is_relative_to(Path(os.environ["HOME"]))

os.environ["HONCHO_BASE_URL"] = "http://127.0.0.1:18000"
os.environ["HONCHO_API_KEY"] = "synthetic-override-key"
os.environ["HONCHO_WORKSPACE_ID"] = "cli-fixture"

loaded = CLIConfig.load()
assert loaded.base_url == "http://127.0.0.1:18000"
assert loaded.resolved_api_key() == "synthetic-override-key"
assert loaded.workspace_id == "cli-fixture"
