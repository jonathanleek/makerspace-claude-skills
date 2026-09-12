# Fusion MCP troubleshooting

Work top-down: each section assumes the ones above it pass. Run
`scripts/check-mcp.sh` first; it tells you which section you are in.

Ground truth (macOS, Fusion 2704.x, 2026-09):

- Endpoint: `http://127.0.0.1:27182/mcp`, streamable HTTP, no auth, served by
  the Fusion process itself (`lsof -nP -iTCP:27182 -sTCP:LISTEN` shows
  `Autodesk`). Server identifies as `MCP Server Adapter 1.0.0`.
- Switch: Preferences > General > API > "Fusion MCP Server (runs locally on
  this device)". Backing store:
  `~/Library/Application Support/Autodesk/Neutron Platform/Options/NMachineSpecificOptions.xml`
  → `<MCPServerEnabled ... Value="1"/>`. A non-default port shows up there as
  `MCPServerPort` (only present once changed).
- Claude Code talks to it through an `mcpServers` entry named `fusion`, type
  `http`. Entries are stored in `~/.claude.json`, either at top level (user
  scope) or under `projects.<absolute path>` (local/project scope).

## §A - Fusion will not launch / never reaches Home

| Symptom | Cause | Fix |
|---|---|---|
| `open -a "Autodesk Fusion"` → "Unable to find application" | Launcher missing from `~/Applications` | `mdfind "kMDItemCFBundleIdentifier == 'com.autodesk.dls.streamer.scriptapp.Autodesk-Fusion'"`; if nothing, reinstall from manage.autodesk.com. |
| Process appears then disappears within seconds | Streamer is applying an update | Wait; check `~/Library/Logs/autodesk.webdeploy.streamer.log`. Relaunch after it goes quiet. |
| Stuck on splash / sign-in window | Needs Autodesk login or is waiting on the Identity Manager helper | Sign in in the Fusion window. If the sign-in window is blank, quit Fusion, `pkill -f "Autodesk Identity Manager"`, relaunch. |
| Home screen loads, but the port never opens | MCP preference is off (see §B) or Fusion needs one restart after enabling | Enable, Apply, quit and relaunch Fusion. |
| Fusion is open but "Untitled" tab is missing and everything is greyed | Fusion is in Home / Data panel view, no design | Fine for the handshake; Step 3 creates a document. Document-dependent tools will fail until then (§D). |

Launch timing: 30-90 s from `open` to a usable Home screen on this machine.
`check-mcp.sh --wait 180` polls for you.

## §B - `check-mcp.sh` fails at a layer

### B1 `Preference MCPServerEnabled=0` or `not found`

1. In Fusion: user avatar (top right) > **Preferences** > **General** > **API**.
2. Tick **Fusion MCP Server (runs locally on this device)**. Note the **port**
   next to it (default 27182).
3. **Apply**, then **quit and relaunch Fusion**. Toggling without a restart
   has been unreliable.
4. Re-run the script. `MCPServerEnabled` must now read `1`.

Autodesk's own KB confirms this is the number-one cause: the connector reports
"connection refused" or presents the environment as incompatible when the
preference is off.

### B2 `Nothing is listening on 127.0.0.1:27182`

- Fusion still loading → wait / `--wait`.
- Preference off → B1.
- Preference on, Fusion fully loaded, still closed → the adapter did not
  start. Quit Fusion fully (`pkill -f "Autodesk Fusion"` if the Quit menu
  hangs), relaunch. If it persists across a restart, toggle the preference
  off → Apply → on → Apply → restart again.

### B3 `Port 27182 is owned by something else`

Another process grabbed the port before Fusion. Either quit it, or change the
port in Preferences > General > API, restart Fusion, and update the client:

```sh
claude mcp remove fusion
claude mcp add --transport http --scope user fusion http://127.0.0.1:<newport>/mcp
```

Then `FUSION_MCP_PORT=<newport> check-mcp.sh`.

### B4 Port is open but the handshake fails / hangs

The listener is up but the adapter isn't answering JSON-RPC. Seen after
sleep/wake and after Fusion auto-updates in the background.

1. `curl -s -m 5 -X POST http://127.0.0.1:27182/mcp -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"x","version":"0"}}}'`
   A healthy server answers with `"serverInfo":{"name":"MCP Server Adapter"...}`
   and an `MCP-Session-Id` header. HTTP 404 means you hit the wrong path
   (it must be `/mcp`; `/` is 404 by design).
2. If there is no answer or a 5xx: dismiss any modal dialog in Fusion (a
   modal blocks the adapter's event loop), then retry.
3. Still dead: restart Fusion.

### B5 Tool list is missing `fusion_mcp_read` / `fusion_mcp_execute`

Autodesk ships "dynamic tooling"; the set changes between releases. Re-read
`tools/list`, then update this skill's SKILL.md table and Step 3 to the new
names. Don't assume the old names still exist.

## §C - Server passes, but Claude cannot see or call the tools

### C1 `mcp__fusion__*` tools are not in the session

Claude Code connects HTTP MCP servers when the session starts. If Fusion was
not up yet, the server shows as failed and its tools never load.

1. `claude mcp get fusion`
   - **"No MCP server named fusion"** → the entry does not exist for *this
     directory*. Check where it does exist:
     `python3 -c "import json,os;d=json.load(open(os.path.expanduser('~/.claude.json')));print([p for p,v in d.get('projects',{}).items() if 'fusion' in v.get('mcpServers',{})]); print('user-scope:', 'fusion' in d.get('mcpServers',{}))"`
     A project-scoped entry under a path that no longer exists (renamed or
     moved repo) is a stale entry: it never fires anywhere. Register at user
     scope instead so every directory gets it:
     `claude mcp add --transport http --scope user fusion http://127.0.0.1:27182/mcp`
   - Entry exists with a different URL/port → `claude mcp remove fusion`, re-add.
2. Reconnect: type `/mcp`, pick `fusion`, reconnect. If the server still shows
   failed, or `/mcp` doesn't list it, **restart the Claude Code session** with
   Fusion already running.
3. Re-run `check-mcp.sh`; its last line should now PASS.

### C2 Tools are listed but every call is refused by permissions

`~/.claude/settings.json` `permissions.allow` currently whitelists
`mcp__fusion__fusion_mcp_read` only. Execute/update calls will prompt each
time (or be denied in non-interactive runs). Add
`mcp__fusion__fusion_mcp_execute` and `mcp__fusion__fusion_mcp_update` if you
want them unprompted; leave them out if you want to approve every script.

### C3 Calls time out mid-session

Fusion was restarted, slept, or crashed after the session connected; the
session still holds the old connection. `/mcp` → reconnect `fusion`. If the
handshake in §B4 also fails, fix Fusion first.

## §D - Tool calls error

| Error text (approx.) | Cause | Fix |
|---|---|---|
| "no active document" / `activeProduct` is `None` | Fusion is on the Home screen | Run the Step 3 new-document script, then retry. |
| "Cannot ... during interactive operation" (undo/redo) or a read that hangs | A command dialog is open in Fusion | Read it with `fusion_mcp_read` `{"queryType":"activeCommand"}`; tell the user to OK/Cancel it (or press Esc in Fusion). |
| "Requires an active Electronics document" | Only for `fusion_mcp_electronics_read` | Open a schematic/board, or don't use that tool for a mechanical design. |
| Python traceback from the script | Script bug; the tool returns the exception on purpose | Read the traceback, look the API up with `{"queryType":"apiDocumentation","searchPattern":"<name>","apiCategory":"all"}`, fix, re-run. Never wrap `run` in try/except. |
| Script "succeeds" but nothing changed | Script printed nothing and didn't touch the design; or acted on a non-active design | Print what you changed; verify with `screenshot` (`direction: "iso-top-right"`) or a document query. |
| `document` `close` refuses | Unsaved changes; the tool needs the user's decision | Ask the user, then pass `userConfirmedSaveAndClose` or `userConfirmedCloseWithoutSave`. |
| `document` `save` on an `Untitled` doc fails | Never-saved documents need `saveAs` with a folder | Use the `saveAs` script in SKILL.md Step 3, only if the user asked to save. |

## §E - Claude Desktop / Cowork instead of Claude Code

Same server, different client. Cowork does not read `~/.claude.json`.

1. Claude Desktop > **Customize** > **Connectors** > **+** > search
   **Fusion** > Install > Enable > **Configure**.
2. Set the port to match Preferences > General > API (27182 by default).
3. Fusion must already be running, ideally with a document open, before the
   connector is toggled on; the connector modifies the live session, it does
   not start Fusion.
4. "Server transport closed unexpectedly" immediately after initialize (a
   forum-reported Windows failure) → §B4 checks apply; a plain restart of both
   Fusion and Claude Desktop, in that order, is the reported workaround.

Sources: Autodesk KB "Third-Party AI Tools (Claude, Cursor, VS Code) Fail to
Connect to Autodesk Fusion MCP"; Autodesk Help "Autodesk Fusion MCPs
Overview" (help.autodesk.com, guid FMCP-OVERVIEW); Autodesk Fusion blog
"How to Improve Your Fusion Workflow with the Claude Desktop Connector";
Autodesk Community thread "Fusion MCP Server disconnects immediately after
initialize" (forums.autodesk.com td-p/14139904).
