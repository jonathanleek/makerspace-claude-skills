---
name: fusion-start
description: Start a Fusion (Autodesk Fusion 360) session for CAD work - launch Fusion, verify the built-in Fusion MCP server is reachable and wired into Claude, and open a new design document. Use for "start fusion", "open fusion", "new fusion file/project", or whenever the Fusion MCP tools are missing, failing, or "not connected". Includes step-by-step troubleshooting for the MCP handshake.
---

# Fusion Start

Gets a Fusion session to a known-good state in three steps, and diagnoses
whichever step fails. Every check is a real probe, never an assumption.

**How the pieces fit** (verified 2026-09 on Fusion 2704.x, macOS):

| Piece | Fact |
|---|---|
| App | `~/Applications/Autodesk Fusion.app` (a launcher; the real binary lives under `~/Library/Application Support/Autodesk/webdeploy/production/<hash>/`). `open -a "Autodesk Fusion"` works. |
| MCP server | **Built into Fusion** (Autodesk's own "MCP Server Adapter"). No add-in, no separate process. Streamable HTTP at `http://127.0.0.1:27182/mcp`, no auth. |
| Enable switch | Fusion **Preferences > General > API > "Fusion MCP Server (runs locally on this device)"**. Stored as `<MCPServerEnabled Value="1"/>` in `~/Library/Application Support/Autodesk/Neutron Platform/Options/NMachineSpecificOptions.xml`. |
| Tools exposed | `fusion_mcp_read` (documents, projects, screenshot, API docs, active command), `fusion_mcp_execute` (run a Python script in Fusion; open/close/save documents), `fusion_mcp_update` (undo/redo), `fusion_mcp_electronics_read`. In Claude Code they appear as `mcp__fusion__<name>`. |
| Claude Code entry | `claude mcp add --transport http --scope user fusion http://127.0.0.1:27182/mcp` |
| Diagnostic | `scripts/check-mcp.sh` (relative to this skill) probes each layer with curl only, so it works even when Claude's MCP entry is broken. |

The server only exists while Fusion is running, and Claude Code only connects
to HTTP MCP servers at **session start** (or on `/mcp` → reconnect). So the
usual failure is simply ordering: Claude started before Fusion finished
loading. Steps below are written to survive that.

## Step 1 - Launch Fusion

1. Check whether it is already running:
   ```sh
   pgrep -f "Autodesk Fusion.app/Contents/MacOS/Autodesk Fusion"
   ```
2. If not, launch it and wait for the MCP port to come up (the script polls the
   handshake every 5 s, up to 120 s by default):
   ```sh
   open -a "Autodesk Fusion"
   ~/.claude/skills/fusion-start/scripts/check-mcp.sh --wait 180
   ```
   Fusion takes 30-90 s to reach the Home screen. It may stop at a sign-in
   window or an update prompt; the port stays closed until that is dismissed,
   so if the wait times out, tell the user to look at the Fusion window.

**If launch fails** → `references/troubleshooting.md` §A.

## Step 2 - Confirm the MCP server is working

Two layers must both pass: the server itself, then Claude's connection to it.

1. **Server layer** - run the diagnostic:
   ```sh
   ~/.claude/skills/fusion-start/scripts/check-mcp.sh
   ```
   It prints one PASS/FAIL line per layer (process, preference, port owner,
   initialize handshake, tool list, open documents, Claude Code registration)
   and a remedy for each FAIL. Anything short of `RESULT: OK` → fix that line
   first using `references/troubleshooting.md` §B; do not proceed on a FAIL.

2. **Claude layer** - call the tool from this session:
   `mcp__fusion__fusion_mcp_read` with `{"queryType": "document", "operation": "open"}`.
   - Success returns `{"success": true, "results": [...]}` listing open documents.
   - If the tool is **not in the session's tool list**, the `fusion` MCP entry
     is missing or was down when the session started. Do this, in order:
     1. `claude mcp get fusion` - if it says no such server, register it at
        user scope (see the table above) so it works in every directory.
        Project-scoped entries silently die when a directory is renamed
        (this happened: the entry lived under a path that no longer exists).
     2. Type `/mcp` in the session and reconnect `fusion`; if that option
        isn't offered, restart the Claude Code session now that Fusion is up.
   - If the tool exists but the call **errors** → `references/troubleshooting.md` §C.

Report the server state plainly: Fusion version, number of open documents, the
active document's name, and whether it has unsaved changes.

## Step 3 - Open a new file

`fusion_mcp_execute` has no "new document" operation, so create it with a
script (tested; returns the new document as active):

```json
{
  "featureType": "script",
  "object": {
    "script": "import adsk.core, adsk.fusion\n\ndef run(_context: str):\n    app = adsk.core.Application.get()\n    doc = app.documents.add(adsk.core.DocumentTypes.FusionDesignDocumentType)\n    design = adsk.fusion.Design.cast(app.activeProduct)\n    design.designType = adsk.fusion.DesignTypes.ParametricDesignType\n    print('active:', app.activeDocument.name, '| open:', app.documents.count)\n"
  }
}
```

Then verify with the `document`/`open` read query: the new document is
`Untitled`, `isActive: true`, `isSaved: false`.

**Naming and saving.** A new document cannot be renamed until it is saved, and
the Fusion tool contract says never save unless the user asked. So:
- If the user gave a **name** (and optionally a project), save once with
  `Document.saveAs(name, dataFolder, description, tag)`:
  ```python
  import adsk.core

  def run(_context: str):
      app = adsk.core.Application.get()
      folder = app.data.activeProject.rootFolder          # or pick a project by name
      # for proj in app.data.activeHub.dataProjects: if proj.name == "<Project>": folder = proj.rootFolder
      ok = app.activeDocument.saveAs("<Name>", folder, "", "")
      print("saved:", ok, "|", app.activeDocument.name)
  ```
  List projects first with `fusion_mcp_read` `{"queryType": "projects"}` if
  the user named one, and confirm the match before saving.
- If no name was given, leave it `Untitled` and say so. Don't invent a name.

If the user wants an **existing** file instead: `fusion_mcp_read`
`{"queryType":"document","operation":"search","name":"<partial>"}` → take the
`id` → `fusion_mcp_execute` `{"featureType":"document","object":{"operation":"open","fileId":"<id>"}}`.

**If the script errors** → `references/troubleshooting.md` §D.

## Done

Finish with a one-glance status:

```
Fusion 2704.1.53 running · MCP OK on :27182 · tools: read/execute/update
Active document: Untitled (unsaved)   ← or "<Name>" saved to <Project>
```

Then hand off: the user can now ask for modeling work directly
(`fusion_mcp_execute` scripts, `screenshot` queries to verify). Look up
unfamiliar API calls with the `apiDocumentation` query before writing scripts;
never wrap the script's `run` in try/except (the tool needs the exception).

## Troubleshooting index

Full decision tree in `references/troubleshooting.md`:

- **§A** Fusion won't launch or never reaches the Home screen
- **§B** `check-mcp.sh` fails at a given layer (pref off, port taken, handshake dead)
- **§C** Server is fine but Claude can't see or call the tools
- **§D** Tool calls error (no active document, modal dialog, script exceptions)
- **§E** Claude Desktop / Cowork connector (different client, same server)
