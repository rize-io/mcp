# Rize for Claude Desktop

Connects Claude to your [Rize](https://rize.io) workspace — automatic time tracking for professionals and teams.

## What it does

The extension runs a small local process that proxies Claude's MCP requests to Rize's hosted MCP server at `https://mcp.rize.io/mcp`. It exposes the same tools as the hosted connector:

- **Time entries** — list, create, update, and delete your own and your team's entries
- **AI suggestions** — generate, regenerate, approve, and reject AI-drafted time entries
- **Time analysis** — allocation by client, project, task, and label; apps used; calendar events
- **Workspace** — clients, projects, tasks, labels, and auto-tagging keywords
- **Team** — rosters, roles, rates, invitations, and removals
- **Profitability** — contracts, revenue, expenses, margins, and monthly trends (org admins only)

## Setup

1. Install the extension in Claude Desktop.
2. The first time Claude starts it, your browser opens Rize's sign-in page.
3. Sign in with a magic link or Google, then approve the requested access.
4. The tools become available in Claude. Tokens refresh automatically; you will not be asked again unless you revoke access.

You need a Rize account. Team and profitability tools require the corresponding plan and an org-admin role.

Requires Node.js 20 or later, which Claude Desktop provides.

## How authentication works

Authorization uses OAuth 2.0 (authorization code with PKCE) and RFC 7591 Dynamic Client Registration — no API key to copy or paste. The extension binds a loopback listener on `127.0.0.1` (port 33418, 33419, or 33420) purely to receive the authorization redirect; it accepts no other traffic and closes as soon as the code arrives.

Credentials are stored in `~/.rize-mcp/credentials.json` with `0600` permissions. Delete that file to disconnect the extension locally; revoke the client in Rize to end access entirely.

## Privacy Policy

Rize's privacy policy: **https://rize.io/privacy-policy**

**What is collected.** The extension itself collects nothing. It forwards the tool calls Claude makes — and their arguments — to Rize's MCP server, which reads and writes data in your own Rize workspace on your behalf. Requests carry the OAuth access token issued to you.

**How it is used and stored.** Tool arguments and responses are processed to serve the request and are logged for operational purposes (error monitoring and abuse prevention) by Rize's hosted server. Your Rize workspace data — time entries, clients, projects, contracts — is stored under the terms of your existing Rize account. OAuth tokens are stored only on your own machine, in `~/.rize-mcp/credentials.json`.

**Third-party sharing.** Rize does not sell your data. Data is shared only with subprocessors that operate the service (hosting, error monitoring), as described in the privacy policy above.

**Retention.** Workspace data is retained for the life of your Rize account and deleted on account deletion. Operational logs are retained on a rolling short-term basis. Local OAuth tokens persist until you delete the credentials file or revoke the client.

**Contact.** Questions or data requests: **support@rize.io**.

## Support

Documentation: https://docs.rize.io/mcp — support: support@rize.io

## License

MIT — see [LICENSE](./LICENSE). Covers the proxy code only.

The Rize name and logo (including `icon.png`) are trademarks of Rize.io and are not licensed under the MIT License. The Rize service is governed by the [Rize Terms of Service](https://rize.io/terms).
