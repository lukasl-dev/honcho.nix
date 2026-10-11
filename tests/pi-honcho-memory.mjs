import assert from "node:assert/strict";
import { once } from "node:events";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [modules, packageDir] = process.argv.slice(2);
const agent = join(modules, "@earendil-works/pi-coding-agent");
const entry = join(packageDir, "extensions/index.ts");
const manifest = JSON.parse(readFileSync(join(packageDir, "package.json")));

assert.deepEqual(manifest.pi.extensions, ["./extensions/index.ts"]);
assert.equal(manifest.peerDependencies.typebox, "*");
assert(existsSync(join(packageDir, "LICENSE")));
assert(!existsSync(join(packageDir, "node_modules/@earendil-works")));

const requests = [];
let fail = false;
const server = createServer(async (request, response) => {
  try {
    assert.equal(request.headers.authorization, "Bearer synthetic-extension-key");
    const url = new URL(request.url, "http://127.0.0.1");
    const parts = [];
    for await (const part of request) parts.push(part);
    const raw = Buffer.concat(parts).toString();
    const body = raw ? JSON.parse(raw) : null;
    requests.push({ method: request.method, path: url.pathname, query: url.searchParams, body });

    response.setHeader("Content-Type", "application/json");
    if (fail) {
      response.writeHead(401);
      response.end(JSON.stringify({ detail: "fixture unavailable" }));
      return;
    }

    const path = url.pathname;
    let result;
    if (path === "/v3/workspaces") {
      result = { id: body.id };
    } else if (path.endsWith("/peers")) {
      result = { id: "fixture-session" };
    } else if (path.endsWith("/context")) {
      result = {
        messages: [],
        peer_representation: "Fixture user prefers small changes.",
        summary: { content: "Fixture project uses native packaging." },
      };
    } else if (path.endsWith("/search")) {
      result = [{ peer_id: "fixture-user", content: "Fixture remembered fact" }];
    } else if (path.endsWith("/chat")) {
      result = { content: "Fixture reasoning response" };
    } else if (path.endsWith("/conclusions")) {
      result = body.conclusions.map((conclusion) => ({ id: "fixture-conclusion", ...conclusion }));
    } else if (path.endsWith("/messages")) {
      result = body.messages.map((message) => ({ id: "fixture-message", ...message }));
    } else {
      throw new Error(`Unexpected fixture request: ${request.method} ${path}`);
    }
    response.end(JSON.stringify(result));
  } catch (error) {
    response.writeHead(400);
    response.end(JSON.stringify({ error: String(error) }));
  }
});

server.listen(0, "127.0.0.1");
await once(server, "listening");
const port = server.address().port;
const fetch = globalThis.fetch;
globalThis.fetch = (input, options) => {
  const url = new URL(input instanceof Request ? input.url : input);
  assert.equal(url.origin, `http://127.0.0.1:${port}`, "Unexpected external request");
  return fetch(input, options);
};

const temporary = mkdtempSync(join(tmpdir(), "honcho-extension-"));
const cwd = join(temporary, "project");
mkdirSync(cwd);
Object.assign(process.env, {
  HONCHO_API_KEY: "synthetic-extension-key",
  HONCHO_URL: `http://127.0.0.1:${port}`,
  HONCHO_WORKSPACE_ID: "fixture-workspace",
  HONCHO_PEER_NAME: "fixture-user",
  HONCHO_AI_PEER: "fixture-assistant",
  HONCHO_SESSION_STRATEGY: "directory",
  HONCHO_CONTEXT_TOKENS: "37",
  HONCHO_SEARCH_LIMIT: "2",
  HONCHO_MAX_MESSAGE_LENGTH: "60",
  HONCHO_TOOL_PREVIEW_LENGTH: "500",
  HONCHO_ENABLED: "true",
});

try {
  const sdk = await import(pathToFileURL(join(agent, "dist/index.js")));
  const { loadExtensions } = await import(pathToFileURL(join(agent, "dist/core/extensions/loader.js")));
  const loaded = await loadExtensions([entry], cwd);
  assert.deepEqual(loaded.errors, []);
  assert.equal(loaded.extensions.length, 1);
  const extension = loaded.extensions[0];
  assert.deepEqual([...extension.tools.keys()].sort(), ["honcho_chat", "honcho_remember", "honcho_search"]);
  assert.deepEqual([...extension.commands.keys()].sort(), ["honcho-setup", "honcho-status"]);
  assert(!extension.handlers.has("session_switch"));
  assert(!extension.handlers.has("session_fork"));

  const resources = new sdk.DefaultResourceLoader({
    cwd,
    agentDir: join(temporary, "agent"),
    settingsManager: sdk.SettingsManager.inMemory({ packages: [packageDir] }),
  });
  await resources.reload();
  const discovered = resources.getExtensions();
  assert.deepEqual(discovered.errors, []);
  assert.equal(discovered.extensions.length, 1, "Package discovery must not load helper modules");

  const statuses = [];
  const context = {
    cwd,
    ui: {
      theme: { fg: (_color, text) => text },
      setStatus: (_id, text) => statuses.push(text),
    },
  };
  const emit = async (name, event = {}) => {
    const handlers = extension.handlers.get(name);
    assert(handlers?.length, `Missing lifecycle handler: ${name}`);
    let result;
    for (const handler of handlers) result = await handler(event, context);
    return result;
  };
  const execute = (name, params) => extension.tools.get(name).definition.execute(
    "fixture-call", params, new AbortController().signal, undefined, context,
  );

  await emit("session_start");
  const prompt = await emit("before_agent_start", { systemPrompt: "Fixture system prompt" });
  assert(statuses.includes("🧠 Connected"), JSON.stringify(requests));
  assert.equal(prompt.systemPrompt, "Fixture system prompt\n\n[Persistent memory]\nUser profile:\nFixture user prefers small changes.\n\nProject summary:\nFixture project uses native packaging.");
  const membership = requests.find((request) => request.path.endsWith("/peers"));
  assert.deepEqual(Object.keys(membership.body).sort(), ["fixture-assistant", "fixture-user"]);
  const memory = requests.find((request) => request.path.endsWith("/context"));
  assert.equal(memory.query.get("tokens"), "37");

  const search = await execute("honcho_search", { query: "fixture query" });
  assert.equal(search.content[0].text, "1. [fixture-user] Fixture remembered fact");
  assert.equal(requests.at(-1).body.limit, 2);
  const chat = await execute("honcho_chat", { query: "fixture question", reasoningLevel: "high" });
  assert.equal(chat.content[0].text, "Fixture reasoning response");
  assert.equal(requests.at(-1).body.reasoning_level, "high");
  assert.equal(requests.at(-1).body.target, "fixture-user");
  await execute("honcho_remember", { content: "Fixture durable fact" });
  assert.equal(requests.at(-1).body.conclusions[0].observer_id, "fixture-assistant");
  assert.equal(requests.at(-1).body.conclusions[0].observed_id, "fixture-user");

  await emit("agent_end", {
    messages: [
      { role: "user", content: "Fixture user text" },
      { role: "assistant", content: [{ type: "text", text: "Fixture assistant text" }] },
      { role: "toolResult", content: "Not conversational memory" },
      { role: "user", content: "x".repeat(61) },
    ],
  });
  await emit("session_before_compact");
  const saved = requests.find((request) => request.path.endsWith("/messages"));
  assert.deepEqual(saved.body.messages.map(({ peer_id, content }) => [peer_id, content]), [
    ["fixture-user", "Fixture user text"], ["fixture-assistant", "Fixture assistant text"],
  ]);

  fail = true;
  await emit("session_start");
  assert.equal(await emit("before_agent_start", { systemPrompt: "No memory" }), undefined);
  assert.equal(statuses.at(-1), "🧠 Offline");
  await assert.rejects(() => execute("honcho_search", { query: "unavailable" }), /not connected/);

  process.env.HONCHO_ENABLED = "false";
  const count = requests.length;
  await emit("session_start");
  assert.equal(await emit("before_agent_start", { systemPrompt: "No memory" }), undefined);
  assert.equal(statuses.at(-1), "🧠 Honcho off");
  assert.equal(requests.length, count);
  await emit("session_shutdown");
} finally {
  globalThis.fetch = fetch;
  server.closeAllConnections();
  await new Promise((resolve) => server.close(resolve));
  rmSync(temporary, { recursive: true, force: true });
}
