import base64
import contextlib
import hashlib
import hmac
import json
import shlex
from collections import abc
from datetime import timedelta
from typing import TypedDict, cast

from test_driver.machine import QemuMachine


type Json = None | bool | int | float | str | list[Json] | dict[str, Json]
type Subtest = abc.Callable[[str], contextlib.AbstractContextManager[None]]


class Resource(TypedDict):
    id: str
    metadata: dict[str, Json]
    configuration: dict[str, Json]


class ResourcePage(TypedDict):
    items: list[Resource]


def jwt(
    claims: dict[str, Json], secret: str = "honcho-integration-test-jwt-secret"
) -> str:
    def encode(value: bytes) -> str:
        return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")

    header = encode(b'{"alg":"HS256","typ":"JWT"}')
    payload = encode(json.dumps(claims, separators=(",", ":")).encode())
    unsigned = f"{header}.{payload}"
    signature = hmac.new(secret.encode(), unsigned.encode(), hashlib.sha256).digest()
    return f"{unsigned}.{encode(signature)}"


def run_service_test(vm: QemuMachine, client: QemuMachine, phase: Subtest) -> None:
    admin = jwt({"t": "", "ad": True})
    workspace = "/v3/workspaces/integration"

    def request(
        method: str,
        path: str,
        body: dict[str, Json] | None = None,
        *,
        token: str | None = admin,
        expected: int = 200,
    ) -> object:
        command = [
            "curl",
            "--silent",
            "--show-error",
            "--max-time",
            "10",
            "--request",
            method,
            "--write-out",
            "\\n%{http_code}",
        ]
        if token is not None:
            command += ["--header", "Authorization: Bearer " + token]
        if body is not None:
            command += [
                "--header",
                "Content-Type: application/json",
                "--data",
                json.dumps(body),
            ]
        command.append("http://127.0.0.1:8000" + path)

        output = vm.succeed(shlex.join(command))
        response, status = output.rsplit("\n", 1)
        assert int(status) == expected, f"{method} {path}: {status}: {response}"
        return cast(object, json.loads(response))

    def sql(query: str) -> str:
        return vm.succeed(
            "runuser -u postgres -- psql --dbname honcho --no-psqlrc "
            "--tuples-only --no-align --set ON_ERROR_STOP=1 --command "
            + shlex.quote(query)
        ).strip()

    def cli(args: list[str], *, token: str = admin, expected: int = 0) -> object:
        command = [
            "runuser",
            "-u",
            "cli",
            "--",
            "env",
            "HOME=/home/cli",
            "HONCHO_CONFIG_DIR=/home/cli/.honcho-fixture",
            "HONCHO_NO_UPDATE_CHECK=1",
            "HONCHO_BASE_URL=http://127.0.0.1:8000",
            "HONCHO_WORKSPACE_ID=cli-integration",
            "HONCHO_PEER_ID=bob",
            "HONCHO_API_KEY=" + token,
            "honcho",
            *args,
            "--json",
        ]
        code, output = vm.execute(
            shlex.join(command) + " 2>&1", timeout=timedelta(seconds=30)
        )
        assert code == expected, f"CLI exited {code}; expected {expected}: {output}"
        return cast(object, json.loads(output))

    def worker_ready() -> None:
        vm.wait_for_unit("honcho-worker.service")
        vm.wait_until_succeeds(
            "journalctl --no-pager "
            "_SYSTEMD_INVOCATION_ID=$(systemctl show honcho-worker.service "
            "--property InvocationID --value) | grep -F 'Starting polling loop'",
            timeout=timedelta(minutes=2),
        )

    def api_ready() -> None:
        vm.wait_for_unit("honcho.service")
        vm.wait_until_succeeds(
            "curl --fail --silent http://127.0.0.1:8000/health",
            timeout=timedelta(minutes=2),
        )
        assert request("GET", "/health", token=None) == {"status": "ok"}

    def check_saved_resources() -> None:
        for path, resource_id, label in [
            ("/v3/workspaces/list", "integration", "workspace-updated"),
            (workspace + "/peers/list", "alice", "peer-updated"),
            (workspace + "/sessions/list", "conversation", "session-updated"),
        ]:
            page = cast(ResourcePage, request("POST", path, {}))
            assert len(page["items"]) == 1, page
            resource = page["items"][0]
            assert resource["id"] == resource_id
            assert resource["metadata"] == {"label": label}

    def check_no_model_work() -> None:
        assert sql("SELECT EXISTS (SELECT 1 FROM messages)") == "f"
        assert sql("SELECT EXISTS (SELECT 1 FROM documents)") == "f"
        assert (
            sql(
                "SELECT EXISTS (SELECT 1 FROM queue WHERE task_type "
                "IN ('representation', 'summary', 'dream'))"
            )
            == "f"
        )

    try:
        with phase(
            "native PostgreSQL, pgvector migrations and authenticated service startup"
        ):
            vm.start(allow_reboot=True)
            client.start()

            vm.wait_for_unit("postgresql.service")
            vm.wait_for_unit("honcho-test-secrets.service")
            vm.wait_for_unit("honcho-database.service")
            vm.wait_for_unit("honcho-migrate.service")
            api_ready()
            worker_ready()

            assert (
                vm.succeed("stat -c '%a %U %G' /run/honcho-test.env").strip()
                == "600 root root"
            )
            vm.fail("runuser -u honcho -- cat /run/honcho-test.env")
            vm.succeed("test -L /var/lib/honcho/config.toml")
            vm.fail(
                "grep -E 'honcho-integration-test-(jwt-secret|dummy-provider-key)' /var/lib/honcho/config.toml"
            )

            for unit in ["honcho.service", "honcho-worker.service"]:
                pid = int(
                    vm.succeed(f"systemctl show {unit} --property MainPID --value")
                )
                assert pid > 0
                vm.succeed(
                    f"tr '\\0' '\\n' < /proc/{pid}/environ "
                    "| grep -Fx 'LLM_OPENAI_API_KEY=honcho-integration-test-dummy-provider-key'"
                )

            assert (
                sql("SELECT extname FROM pg_extension WHERE extname = 'vector'")
                == "vector"
            )
            revision = sql("SELECT version_num FROM alembic_version")
            assert revision
            assert (
                sql(
                    "SELECT c.relname || ':' || format_type(a.atttypid, a.atttypmod) "
                    "FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid "
                    "JOIN pg_namespace n ON n.oid = c.relnamespace "
                    "WHERE n.nspname = 'public' AND a.attname = 'embedding' "
                    "AND c.relname IN ('documents', 'message_embeddings') ORDER BY c.relname"
                )
                == "documents:vector(1536)\nmessage_embeddings:vector(1536)"
            )

        with phase("loopback API and closed firewall"):
            assert (
                vm.succeed("ss -H -ltn 'sport = :8000'").split()[3] == "127.0.0.1:8000"
            )
            vm.wait_for_unit("firewall.service")
            vm.fail("iptables-save | grep -E -- '--dport 8000( |$)'")

            client.wait_for_unit("multi-user.target")
            client.succeed("ping -c 1 machine")
            client.fail(
                "curl --fail --silent --connect-timeout 3 http://machine:8000/health"
            )

        with phase("missing, invalid and wrongly scoped JWTs are rejected"):
            assert request(
                "POST", "/v3/workspaces/list", {}, token=None, expected=401
            ) == {"detail": "No access token provided"}
            assert request(
                "POST",
                "/v3/workspaces/list",
                {},
                token=jwt({"ad": True}, "wrong-signing-key-for-the-test"),
                expected=401,
            ) == {"detail": "Invalid JWT"}
            assert request(
                "POST",
                "/v3/workspaces",
                {"id": "integration"},
                token=jwt({"w": "other-workspace"}),
                expected=401,
            ) == {"detail": "Unauthorized access to resource"}
            assert (
                cast(ResourcePage, request("POST", "/v3/workspaces/list", {}))["items"]
                == []
            )

        with phase("authenticated workspace, peer and session creation and updates"):
            resource = cast(
                Resource,
                request(
                    "POST",
                    "/v3/workspaces",
                    {"id": "integration", "metadata": {"label": "workspace"}},
                    expected=201,
                ),
            )
            assert resource["id"] == "integration"
            assert resource["metadata"] == {"label": "workspace"}

            resource = cast(
                Resource,
                request(
                    "POST",
                    workspace + "/peers",
                    {"id": "alice", "metadata": {"label": "peer"}},
                    expected=201,
                ),
            )
            assert resource["id"] == "alice"
            assert resource["metadata"] == {"label": "peer"}

            resource = cast(
                Resource,
                request(
                    "POST",
                    workspace + "/sessions",
                    {
                        "id": "conversation",
                        "metadata": {"label": "session"},
                        "peers": {"alice": {}},
                    },
                    expected=201,
                ),
            )
            assert resource["id"] == "conversation"
            assert resource["metadata"] == {"label": "session"}

            scoped = jwt({"w": "integration"})
            for path, label in [
                (workspace, "workspace-updated"),
                (workspace + "/peers/alice", "peer-updated"),
                (workspace + "/sessions/conversation", "session-updated"),
            ]:
                resource = cast(
                    Resource,
                    request("PUT", path, {"metadata": {"label": label}}, token=scoped),
                )
                assert resource["metadata"] == {"label": label}

            check_saved_resources()
            check_no_model_work()

        with phase(
            "API and worker restart ignores hostile dotenv and preserves database state"
        ):
            vm.succeed(
                "printf '%s\\n' 'AUTH_USE_AUTH=false' 'AUTH_JWT_SECRET=hostile-dotenv-secret' "
                "> /var/lib/honcho/.env; "
                "chown honcho:honcho /var/lib/honcho/.env; chmod 0600 /var/lib/honcho/.env"
            )
            old_pids = [
                vm.succeed(f"systemctl show {unit} --property MainPID --value").strip()
                for unit in ["honcho.service", "honcho-worker.service"]
            ]
            vm.succeed("systemctl restart honcho.service honcho-worker.service")
            api_ready()
            worker_ready()

            new_pids = [
                vm.succeed(f"systemctl show {unit} --property MainPID --value").strip()
                for unit in ["honcho.service", "honcho-worker.service"]
            ]
            assert all(old != new for old, new in zip(old_pids, new_pids, strict=True))
            assert sql("SELECT version_num FROM alembic_version") == revision

            check_saved_resources()
            check_no_model_work()
            request("POST", workspace + "/peers/list", {}, token=None, expected=401)

        with phase(
            "full reboot recreates runtime secrets and preserves authenticated resources"
        ):
            boot_id = vm.succeed("cat /proc/sys/kernel/random/boot_id").strip()
            vm.succeed("touch /run/honcho-test-previous-boot")
            vm.reboot()

            vm.wait_for_unit("honcho-test-secrets.service")
            vm.wait_for_unit("honcho-migrate.service")
            api_ready()
            worker_ready()

            assert vm.succeed("cat /proc/sys/kernel/random/boot_id").strip() != boot_id
            vm.succeed("test ! -e /run/honcho-test-previous-boot")
            assert (
                vm.succeed("stat -c '%a %U %G' /run/honcho-test.env").strip()
                == "600 root root"
            )
            vm.fail("runuser -u honcho -- cat /run/honcho-test.env")
            assert sql("SELECT version_num FROM alembic_version") == revision

            check_saved_resources()
            check_no_model_work()
            request("POST", workspace + "/peers/list", {}, token=None, expected=401)
            vm.succeed("rm /var/lib/honcho/.env")

        with phase(
            "worker processes session and workspace deletion without model work"
        ):
            request("DELETE", workspace + "/sessions/conversation", expected=202)
            vm.wait_until_succeeds(
                'test "$(runuser -u postgres -- psql -d honcho -Atc '
                + shlex.quote(
                    "SELECT EXISTS (SELECT 1 FROM sessions WHERE name = 'conversation')"
                )
                + ')" = f',
                timeout=timedelta(minutes=2),
            )
            assert (
                cast(ResourcePage, request("POST", workspace + "/sessions/list", {}))[
                    "items"
                ]
                == []
            )

            request("DELETE", workspace, expected=202)
            vm.wait_until_succeeds(
                'test "$(runuser -u postgres -- psql -d honcho -Atc '
                + shlex.quote(
                    "SELECT EXISTS (SELECT 1 FROM workspaces WHERE name = 'integration')"
                )
                + ')" = f',
                timeout=timedelta(minutes=2),
            )
            assert (
                cast(ResourcePage, request("POST", "/v3/workspaces/list", {}))["items"]
                == []
            )
            assert (
                sql("SELECT EXISTS (SELECT 1 FROM peers WHERE name = 'alice')") == "f"
            )
            check_no_model_work()

        with phase("installed CLI authenticates and manages native-server resources"):
            assert cli(["workspace", "create", "cli-integration"]) == {
                "workspace_id": "cli-integration"
            }
            assert cli(["workspace", "create", "cli-integration"]) == {
                "workspace_id": "cli-integration"
            }

            peer = cast(
                dict[str, Json],
                cli(
                    [
                        "peer",
                        "create",
                        "bob",
                        "--no-observe-me",
                        "--metadata",
                        '{"fixture":true}',
                    ]
                ),
            )
            assert peer["peer_id"] == "bob"
            assert peer["metadata"] == {"fixture": True}
            assert cli(["peer", "get-metadata"]) == {
                "peer_id": "bob",
                "metadata": {"fixture": True},
            }

            assert cli(["session", "create", "cli-conversation", "--peers", "bob"]) == {
                "session_id": "cli-conversation",
                "peers": ["bob"],
            }
            sessions = cast(list[dict[str, Json]], cli(["session", "list"]))
            assert len(sessions) == 1
            assert sessions[0]["id"] == "cli-conversation"

            inspected = cast(dict[str, Json], cli(["workspace", "inspect"]))
            assert inspected["workspace_id"] == "cli-integration"
            assert inspected["peer_count"] == 1
            assert inspected["session_count"] == 1
            membership = cast(
                ResourcePage,
                request(
                    "GET",
                    "/v3/workspaces/cli-integration/sessions/cli-conversation/peers",
                ),
            )
            assert [peer["id"] for peer in membership["items"]] == ["bob"]

            error = cast(
                dict[str, Json],
                cli(["workspace", "list"], token="invalid-jwt", expected=3),
            )
            assert cast(dict[str, Json], error["error"])["code"] == "AUTH_ERROR"
            check_no_model_work()

    except Exception:
        print(vm.execute("systemctl --failed --no-pager")[1])
        print(
            vm.execute(
                "journalctl -u honcho-migrate -u honcho -u honcho-worker --no-pager -n 200"
            )[1]
        )
        raise


run_service_test(
    cast(QemuMachine, globals()["machine"]),
    cast(QemuMachine, globals()["client"]),
    cast(Subtest, globals()["subtest"]),
)
