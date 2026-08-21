#!/usr/bin/env node
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { UnauthorizedError } from "@modelcontextprotocol/sdk/client/auth.js";
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  GetPromptRequestSchema,
  ListPromptsRequestSchema,
  ListResourceTemplatesRequestSchema,
  ListResourcesRequestSchema,
  ListToolsRequestSchema,
  ReadResourceRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { FileOAuthProvider, startCallbackListener } from "./oauth.js";

const here = dirname(fileURLToPath(import.meta.url));
const { version } = JSON.parse(readFileSync(join(here, "..", "manifest.json"), "utf8"));
const SERVER_URL = new URL(process.env.RIZE_MCP_URL ?? "https://mcp.rize.io/mcp");

// stdout carries the MCP framing, so all diagnostics go to stderr.
const log = (message) => process.stderr.write(`[rize-mcp] ${message}\n`);

async function connectRemote() {
  const callback = await startCallbackListener();
  const authProvider = new FileOAuthProvider({ redirectUrl: callback.redirectUrl });
  const client = new Client({ name: "rize-desktop-extension", version });

  try {
    try {
      await client.connect(new StreamableHTTPClientTransport(SERVER_URL, { authProvider }));
    } catch (error) {
      if (!(error instanceof UnauthorizedError)) throw error;
      log("Opening your browser to sign in to Rize...");
      const transport = new StreamableHTTPClientTransport(SERVER_URL, { authProvider });
      await transport.finishAuth(await callback.waitForCode());
      await client.connect(transport);
    }
  } finally {
    callback.close();
  }

  return client;
}

// Forwards a request to the remote server, letting its errors surface unchanged
// so Claude sees the real tool failure rather than a proxy wrapper.
function forward(server, schema, handler) {
  server.setRequestHandler(schema, (request, extra) =>
    handler(request.params ?? {}, { signal: extra.signal })
  );
}

const remote = await connectRemote();
const capabilities = remote.getServerCapabilities() ?? {};
const proxy = new Server(
  { name: "rize", version },
  { capabilities, instructions: remote.getInstructions() }
);

if (capabilities.tools) {
  forward(proxy, ListToolsRequestSchema, (params, options) => remote.listTools(params, options));
  forward(proxy, CallToolRequestSchema, (params, options) => remote.callTool(params, undefined, options));
}
if (capabilities.prompts) {
  forward(proxy, ListPromptsRequestSchema, (params, options) => remote.listPrompts(params, options));
  forward(proxy, GetPromptRequestSchema, (params, options) => remote.getPrompt(params, options));
}
if (capabilities.resources) {
  forward(proxy, ListResourcesRequestSchema, (params, options) => remote.listResources(params, options));
  forward(proxy, ListResourceTemplatesRequestSchema, (params, options) =>
    remote.listResourceTemplates(params, options)
  );
  forward(proxy, ReadResourceRequestSchema, (params, options) => remote.readResource(params, options));
}

// A dropped remote session must take the stdio server down with it; Claude
// Desktop restarts the extension and the stored refresh token reconnects.
remote.onclose = () => {
  log("Remote connection closed.");
  process.exit(0);
};

await proxy.connect(new StdioServerTransport());
log(`Connected to ${SERVER_URL.href}`);
