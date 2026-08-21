import { createServer } from "node:http";
import { mkdir, chmod, readFile, writeFile, rm } from "node:fs/promises";
import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

const CREDENTIALS_PATH =
  process.env.RIZE_MCP_CREDENTIALS_PATH ?? join(homedir(), ".rize-mcp", "credentials.json");
const CALLBACK_PORTS = [33418, 33419, 33420];

async function readCredentials() {
  try {
    return JSON.parse(await readFile(CREDENTIALS_PATH, "utf8"));
  } catch {
    return {};
  }
}

async function writeCredentials(patch) {
  const merged = { ...(await readCredentials()), ...patch };
  await mkdir(dirname(CREDENTIALS_PATH), { recursive: true, mode: 0o700 });
  await writeFile(CREDENTIALS_PATH, JSON.stringify(merged, null, 2));
  await chmod(CREDENTIALS_PATH, 0o600);
}

function openBrowser(url) {
  const command =
    process.platform === "darwin" ? "open" : process.platform === "win32" ? "start" : "xdg-open";
  const args = process.platform === "win32" ? ["", url] : [url];
  spawn(command, args, { detached: true, stdio: "ignore", shell: process.platform === "win32" })
    .on("error", () => {})
    .unref();
}

// Binds one loopback listener up front: the redirect_uri is registered with the
// authorization server before the browser opens, so the port cannot shift later.
export async function startCallbackListener() {
  for (const port of CALLBACK_PORTS) {
    const pending = { resolve: undefined, reject: undefined };
    const received = new Promise((resolve, reject) => {
      pending.resolve = resolve;
      pending.reject = reject;
    });
    // A denial can land before anything awaits waitForCode(); without this the
    // rejection is unhandled and takes the process down.
    received.catch(() => {});

    const server = createServer((req, res) => {
      const url = new URL(req.url, `http://127.0.0.1:${port}`);
      if (url.pathname !== "/callback") {
        res.writeHead(404).end();
        return;
      }
      const code = url.searchParams.get("code");
      const error = url.searchParams.get("error");
      res.writeHead(200, { "content-type": "text/html" });
      res.end(
        `<html><body style="font-family:system-ui;padding:3rem;text-align:center">` +
          `<h2>${code ? "Rize connected" : "Rize authorization failed"}</h2>` +
          `<p>${code ? "You can close this tab and return to Claude." : escapeHtml(error ?? "No authorization code was returned.")}</p>` +
          `</body></html>`
      );
      if (code) pending.resolve(code);
      else pending.reject(new Error(`Authorization failed: ${error ?? "no code returned"}`));
    });

    const listening = await new Promise((resolve) => {
      server.once("error", () => resolve(false));
      server.listen(port, "127.0.0.1", () => resolve(true));
    });
    if (!listening) continue;

    return {
      redirectUrl: `http://127.0.0.1:${port}/callback`,
      waitForCode: () => received,
      close: () => server.close(),
    };
  }
  throw new Error(
    `Could not bind an OAuth callback port (tried ${CALLBACK_PORTS.join(", ")}). Free one and restart Claude.`
  );
}

function escapeHtml(value) {
  return String(value).replace(
    /[&<>"']/g,
    (char) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]
  );
}

export class FileOAuthProvider {
  #redirectUrl;
  #onAuthorizationUrl;

  constructor({ redirectUrl, onAuthorizationUrl = openBrowser }) {
    this.#redirectUrl = redirectUrl;
    this.#onAuthorizationUrl = onAuthorizationUrl;
  }

  get redirectUrl() {
    return this.#redirectUrl;
  }

  get clientMetadata() {
    return {
      client_name: "Rize for Claude Desktop",
      client_uri: "https://rize.io",
      redirect_uris: [this.#redirectUrl],
      grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"],
      token_endpoint_auth_method: "none",
    };
  }

  async clientInformation() {
    const { client, redirect_uri: registeredFor } = await readCredentials();
    // A client registered against a different loopback port would fail the
    // redirect_uri check, so drop it and re-register.
    return registeredFor === this.#redirectUrl ? client : undefined;
  }

  async saveClientInformation(client) {
    await writeCredentials({ client, redirect_uri: this.#redirectUrl });
  }

  async tokens() {
    return (await readCredentials()).tokens;
  }

  async saveTokens(tokens) {
    await writeCredentials({ tokens });
  }

  async saveCodeVerifier(codeVerifier) {
    await writeCredentials({ code_verifier: codeVerifier });
  }

  async codeVerifier() {
    const { code_verifier: verifier } = await readCredentials();
    if (!verifier) throw new Error("Missing PKCE code verifier; restart the connection.");
    return verifier;
  }

  async redirectToAuthorization(authorizationUrl) {
    this.#onAuthorizationUrl(authorizationUrl.toString());
  }

  async invalidateCredentials(scope) {
    if (scope === "all") {
      await rm(CREDENTIALS_PATH, { force: true });
      return;
    }
    const key = { tokens: "tokens", client: "client", verifier: "code_verifier" }[scope];
    if (!key) return;
    const credentials = await readCredentials();
    delete credentials[key];
    await mkdir(dirname(CREDENTIALS_PATH), { recursive: true, mode: 0o700 });
    await writeFile(CREDENTIALS_PATH, JSON.stringify(credentials, null, 2));
    await chmod(CREDENTIALS_PATH, 0o600);
  }
}
