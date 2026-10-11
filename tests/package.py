import sys
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
