// Exercises the published extension against the runtime Claude Desktop uses:
// manifest shape, entry point, and the loopback OAuth callback listener.
// Runs with `node --test .github/scripts/bundle.test.mjs` from the repository root.
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const root = resolve(import.meta.dirname, "..", "..");
const manifest = JSON.parse(readFileSync(join(root, "manifest.json"), "utf8"));
const pkg = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));

const credentialsDir = mkdtempSync(join(tmpdir(), "rize-mcpb-"));
process.env.RIZE_MCP_CREDENTIALS_PATH = join(credentialsDir, "credentials.json");
process.on("exit", () => rmSync(credentialsDir, { recursive: true, force: true }));

const oauth = await import(pathToFileURL(join(root, "server", "oauth.js")).href);

test("manifest declares an MCPB node server whose entry point exists", () => {
  assert.equal(manifest.manifest_version, "0.3");
  assert.equal(manifest.server.type, "node");
  assert.ok(existsSync(join(root, manifest.server.entry_point)));
  assert.equal(manifest.server.mcp_config.command, "node");
  assert.ok(manifest.server.mcp_config.args[0].endsWith(manifest.server.entry_point));
});

test("entry point imports resolve against installed dependencies", () => {
  const entry = join(root, manifest.server.entry_point);
  const source = readFileSync(entry, "utf8");
  const specifiers = [...source.matchAll(/^import[^"']*["']([^"']+)["']/gm)].map((m) => m[1]);
  assert.ok(specifiers.length > 0);
  for (const specifier of specifiers) {
    assert.ok(import.meta.resolve(specifier, pathToFileURL(entry).href), `unresolved ${specifier}`);
  }
});

test("manifest version matches package.json", () => {
  assert.equal(manifest.version, pkg.version);
});

test("manifest satisfies MCPB directory requirements", () => {
  assert.equal(manifest.license, "MIT");
  assert.match(manifest.author.url, /^https:\/\/github\.com\//);
  assert.ok(manifest.privacy_policies.length > 0);
  for (const url of manifest.privacy_policies) assert.match(url, /^https:\/\//);
  assert.ok(existsSync(join(root, manifest.icon)));
});

test("every declared tool carries a name and description", () => {
  assert.ok(manifest.tools.length > 0);
  const names = new Set();
  for (const tool of manifest.tools) {
    assert.match(tool.name, /^[a-z0-9_]+$/);
    assert.ok(!names.has(tool.name), `duplicate tool ${tool.name}`);
    names.add(tool.name);
    assert.ok(tool.description.length > 20, `${tool.name} description too short`);
  }
});

test("callback listener binds loopback, resolves the code, then closes", async () => {
  const listener = await oauth.startCallbackListener();
  try {
    assert.match(listener.redirectUrl, /^http:\/\/127\.0\.0\.1:\d+\/callback$/);
    const response = await fetch(`${listener.redirectUrl}?code=auth-code-1`);
    assert.equal(response.status, 200);
    assert.equal(await listener.waitForCode(), "auth-code-1");
  } finally {
    listener.close();
  }
});

test("callback listener rejects authorization server errors", async () => {
  const listener = await oauth.startCallbackListener();
  try {
    const pending = listener.waitForCode();
    await fetch(`${listener.redirectUrl}?error=access_denied`);
    await assert.rejects(pending, /access_denied/);
  } finally {
    listener.close();
  }
});

test("credentials are a public PKCE client stored owner-only", async () => {
  const provider = new oauth.FileOAuthProvider({
    redirectUrl: "http://127.0.0.1:33418/callback",
    onAuthorizationUrl: () => {},
  });
  assert.equal(provider.clientMetadata.token_endpoint_auth_method, "none");
  assert.deepEqual(provider.clientMetadata.redirect_uris, ["http://127.0.0.1:33418/callback"]);

  assert.equal(await provider.tokens(), undefined);
  await provider.saveTokens({ access_token: "abc", token_type: "Bearer" });
  assert.deepEqual(await provider.tokens(), { access_token: "abc", token_type: "Bearer" });
  if (process.platform !== "win32") {
    assert.equal(statSync(process.env.RIZE_MCP_CREDENTIALS_PATH).mode & 0o777, 0o600);
  }

  await provider.invalidateCredentials("all");
  assert.equal(await provider.tokens(), undefined);
});
