# Web and UI debugging — Chrome DevTools MCP

> Loaded on demand — not part of the SessionStart payload. Read it before a browser-driven
> rendering or runtime check.

- **For all web/UI debugging, use the Chrome DevTools (Google Chrome) MCP** (`mcp__chrome-devtools__*`) when it is configured.
- **Use the MCP tools directly** — the MCP server launches and manages its own Chrome. Just call `mcp__chrome-devtools__new_page` (or `navigate_page`) with the URL; no manual browser launch is needed.
- **Do NOT hand-launch `google-chrome --remote-debugging-port=...` from Bash.** In a sandboxed shell the process may be killed before it binds the CDP port — wasted round-trips. Let the MCP server own the browser.
- To spoof locale/headers for a page, pass `initScript` to `navigate_page` (e.g. override `navigator.language` before load). To read state, use `evaluate_script`; to check for runtime errors, use `list_console_messages` with `types:['error','warn']`.
- **Token discipline**: `take_screenshot` ALWAYS with `filePath` (inline base64 costs 60k–600k chars per call); prefer `evaluate_script` over `wait_for`/`take_snapshot` for assertions; snapshot once per page state and reuse UIDs; filter `list_network_requests` (`urlPattern`) and `list_console_messages` (`levels:['error','warning']`).
