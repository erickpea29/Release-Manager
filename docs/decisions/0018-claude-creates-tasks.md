# 0018 — Claude creates tasks through MCP

- **Status:** Accepted. The owner asked for Claude sessions to create tasks for a release version; they chose "read + create tasks" and "Claude Code first". Narrows the "AI" non-goal in [PRODUCT_SPEC §5](../PRODUCT_SPEC.md#5-non-goals-mvp).
- **Date:** 2026-10-26

## Context

The owner plans releases with Claude Code: a session that has just designed a feature knows exactly which tasks it needs. They want any session, not just one, to be able to put those tasks on the version being planned.

The facts that shaped the design:

- The **Model Context Protocol (MCP)** is how Claude uses an app's tools. Claude Code connects to MCP servers over stdio or HTTP. `claude mcp add --scope user` makes a server available to every session on the Mac.
- **Relvora's data lives in its sandbox container, and only the running app should write it:**
  - its views show the changes at once;
  - the same rules as the app's own editing apply;
  - there's never a second process writing the SwiftData store.
- Relvora must keep its promises: local-first, tokens in the Keychain, no hosted backend, and every GitHub write confirmed by the user.

## Decisions

1. **An MCP server inside Relvora**, on MCP's Streamable HTTP transport, at `http://127.0.0.1:<port>/mcp`. It runs while Relvora is open and **Settings › Claude** has it on (off by default; port 47823 by default).
   - Requests are answered with plain JSON: no streaming, no sessions.
   - It speaks protocol versions 2025-06-18, 2025-03-26, and 2024-11-05.
   - It's built on Network.framework with no dependency (`RelvoraMCP`: `LoopbackServer`, `MCPEndpoint`, `MCPServer`, `RelvoraTools`).
2. **Tools: reading and creating, nothing else.**
   - `list_projects`: active projects, their groups, the version being planned and its task counts, the Backlog count, and the columns.
   - `list_tasks`: the version's tasks, the Backlog, or all of a project's tasks.
   - `create_tasks`: up to 50 tasks at a time, into the version being planned (the default) or the Backlog, at the end of the first column or a named one.
     - Every task is checked before any is created, and each task goes through `BoardService` like one typed in the app.
     - Not into the completion column: creating a task "done" would be completing it.
     - Every task gets the label **claude**.
   - Claude can't edit, move, complete, or delete tasks, plan versions, or do anything on GitHub. Problems come back as tool errors Claude can explain (no version being planned, unknown column, archived project).
3. **Who can call it.** The MCP specification's safeguards for local servers, plus a key:
   - It **listens on 127.0.0.1 only**; nothing on the network can connect.
   - **The `Host` header must be `127.0.0.1:<port>` or `localhost:<port>`.** This defeats DNS rebinding: a web page that points its own domain at 127.0.0.1 still sends its domain.
   - **Requests with an `Origin` header are refused.** Browsers send one; Claude Code doesn't.
   - **A random access key** (`rlv_` and 32 random bytes) **must come in the `Authorization` header.** It's compared in constant time.
     - It's kept in the Keychain (`com.erickpea29.Relvora.claude`), like the GitHub sign-in.
     - **New Key…** replaces it, so earlier setups stop working.
   - The sandbox gains `com.apple.security.network.server`, which listening needs.
4. **Setting up Claude Code is one command**, copied from Settings: `claude mcp add --scope user --transport http relvora http://127.0.0.1:<port>/mcp --header "Authorization: Bearer <key>"`.
   - Settings shows the command with the key hidden; **Copy Setup Command** copies the whole command.
   - Settings also shows the status, and the last thing Claude did ("Claude added 3 tasks to Relvora 0.2.0").
5. **Changes show at once.** After creating tasks, Relvora refreshes the project's stats and posts an `ExternalChange`. The project's open workspace then reloads its board, without closing editors.
6. **Not included now.**
   - **Claude Desktop:** it starts MCP servers as commands, so it needs a small stdio bridge in the app bundle.
   - **Editing tasks.**
   - **Claude on the web or phone:** it can't reach a Mac's 127.0.0.1.

## Consequences

- Any Claude Code session on the Mac can turn a plan into tasks on the right version, and the owner sees them arrive on the Board, labeled **claude**.
- **Relvora itself still contains no AI and sends nothing to an AI service.** Claude Code, which the user runs and signs in to, reads what Relvora answers.
- **Relvora must be open.** When it isn't, Claude Code reports the server as unavailable.
- **The key is also in Claude Code's settings** (`~/.claude.json`) after setup. Anything running as the user can read that file, as it can most of the user's data. The key's job is to keep other users, web pages, and other machines out.
- **Port conflicts** show in Settings ("Another app is using the port") and are fixed by changing the port and running the setup command again.
- **No schema, backup, or GitHub permission change.** The label is a normal label.

## Evidence

- Package tests (18 new):
  - **the HTTP parser**: partial, malformed, chunked, and oversized requests;
  - **the endpoint**:
    - `initialize` and version negotiation, tools, notifications, batches;
    - refusals for another host, another port, an Origin, no key, a wrong or longer key, an unknown protocol version, or a non-JSON body;
  - **a real request over 127.0.0.1**;
  - **the tools on an in-memory store**:
    - listing, and creating in a version, in the Backlog, or in a named column;
    - nothing created when any task is invalid;
    - no version being planned; the limit of 50;
  - **access keys.**
- **The sandboxed app:**
  - answered `initialize`, `tools/list`, and `list_projects` from curl;
  - created two tasks that appeared on the open Board at once;
  - refused a wrong key (401), an Origin (403), and a rebinding `Host` (403);
  - didn't answer on the Mac's network address.
- **Claude Code 2.1.309**, with a one-off configuration pointed at a test copy, listed the projects and added a task to the version being planned on its own.
- UI tests (24 pass, two new): a task created over MCP appears on the open Board, Settings › Claude shows the status and the activity, and a request without the key is refused.
