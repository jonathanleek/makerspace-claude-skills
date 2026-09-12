#!/usr/bin/env bash
#
# check-mcp.sh — diagnose the Autodesk Fusion MCP server layer by layer.
#
# Fusion's MCP server is built into the desktop app (Preferences > General >
# API > "Fusion MCP Server"). It speaks streamable HTTP on 127.0.0.1:27182/mcp.
# This script needs nothing but curl + python3, so it works even when Claude
# Code's own `fusion` MCP entry is broken — which is exactly when you need it.
#
# Usage:
#   check-mcp.sh                # run every check once
#   check-mcp.sh --wait [SECS]  # poll the handshake until it passes (default 120 s)
#   FUSION_MCP_PORT=27183 check-mcp.sh   # non-default port
#
# Exit code: 0 = every check passed, 1 = something failed (see the FAIL lines).

set -uo pipefail

port="${FUSION_MCP_PORT:-27182}"
url="http://127.0.0.1:${port}/mcp"
wait_secs=0
if [[ "${1:-}" == "--wait" ]]; then wait_secs="${2:-120}"; fi

opts_xml="$HOME/Library/Application Support/Autodesk/Neutron Platform/Options/NMachineSpecificOptions.xml"
proc_pattern='Autodesk Fusion.app/Contents/MacOS/Autodesk Fusion'
fail=0
pass() { printf 'PASS  %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; fail=1; }
hint() { printf '      -> %s\n' "$*"; }

hdr=(-H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream')
init_body='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"check-mcp","version":"1"}}}'

handshake() {
  # prints the MCP-Session-Id on success; returns 1 on failure
  local resp
  resp=$(curl -s -m 5 -i -X POST "$url" "${hdr[@]}" -d "$init_body" 2>/dev/null) || return 1
  grep -q '"serverInfo"' <<<"$resp" || return 1
  grep -i '^MCP-Session-Id' <<<"$resp" | awk '{print $2}' | tr -d '\r'
}

# 1. Fusion process
if pgrep -f "$proc_pattern" >/dev/null; then
  pass "Fusion is running (pid $(pgrep -f "$proc_pattern" | head -1))"
else
  fail "Fusion is not running"
  hint 'open -a "Autodesk Fusion"   (then wait ~30-90 s for the splash + sign-in to finish)'
fi

# 2. Preference: MCP server enabled? (BSD grep treats the XML as binary, so parse it)
if [[ -f "$opts_xml" ]]; then
  read -r enabled custom_port < <(python3 - "$opts_xml" <<'PY'
import sys, xml.etree.ElementTree as ET
en, port = "missing", ""
for el in ET.parse(sys.argv[1]).getroot().iter():
    if el.tag == "MCPServerEnabled": en = el.attrib.get("Value", "missing")
    if el.tag == "MCPServerPort":    port = el.attrib.get("Value", "")
print(en, port)
PY
)
  case "$enabled" in
    1) pass "Preference MCPServerEnabled=1 (Preferences > General > API)";;
    0) fail "Preference MCPServerEnabled=0 — the server is switched off"
       hint "In Fusion: Preferences > General > API > tick 'Fusion MCP Server (runs locally on this device)' > Apply, then restart Fusion";;
    *) warn "MCPServerEnabled not found in NMachineSpecificOptions.xml (never toggled?) — check Preferences > General > API";;
  esac
  if [[ -n "${custom_port:-}" && "$custom_port" != "$port" ]]; then
    fail "Fusion preference sets port $custom_port but this check is using $port"
    hint "Re-run with FUSION_MCP_PORT=$custom_port, and point Claude's fusion MCP entry at that port too"
  fi
else
  warn "Options file not found: $opts_xml"
fi

# 3. Something listening on the port?
listener=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $1" pid="$2}' | head -1)
if [[ -n "$listener" ]]; then
  if [[ "$listener" == Autodesk* ]]; then
    pass "Port $port is owned by Fusion ($listener)"
  else
    fail "Port $port is owned by something else: $listener"
    hint "Quit that process, or change the port in Fusion Preferences > General > API and in Claude's MCP entry"
  fi
else
  fail "Nothing is listening on 127.0.0.1:$port"
  hint "Fusion still loading (wait, or --wait), server disabled in Preferences, or Fusion needs a restart after enabling it"
fi

# 4. MCP initialize handshake (optionally wait for it)
sid=""
deadline=$(( $(date +%s) + wait_secs ))
while :; do
  sid=$(handshake) && break
  if (( $(date +%s) >= deadline )); then break; fi
  printf '      waiting for %s ...\n' "$url"; sleep 5
done
if [[ -n "$sid" ]]; then
  pass "MCP initialize handshake OK at $url (session $sid)"
else
  fail "MCP initialize handshake failed at $url"
  hint "If the port IS listening: restart Fusion (the adapter sometimes stalls after sleep/wake or an update)"
  echo; echo "RESULT: FAIL"; exit 1
fi
curl -s -m 5 -X POST "$url" "${hdr[@]}" -H "MCP-Session-Id: $sid" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null

# 5. Tools present?
tools=$(curl -s -m 10 -X POST "$url" "${hdr[@]}" -H "MCP-Session-Id: $sid" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | python3 -c 'import json,sys; print(" ".join(t["name"] for t in json.load(sys.stdin)["result"]["tools"]))' 2>/dev/null)
if grep -q fusion_mcp_read <<<"$tools" && grep -q fusion_mcp_execute <<<"$tools"; then
  pass "Tools: $tools"
else
  fail "Expected fusion_mcp_read + fusion_mcp_execute, got: ${tools:-<none>}"
  hint "Fusion update changed the tool set? Re-read tools/list and update the skill"
fi

# 6. Active document?
docs=$(curl -s -m 10 -X POST "$url" "${hdr[@]}" -H "MCP-Session-Id: $sid" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"fusion_mcp_read","arguments":{"queryType":"document","operation":"open"}}}' \
  | python3 -c '
import json,sys
r=json.load(sys.stdin)["result"]
if r.get("isError"): print("ERROR " + r["content"][0]["text"][:200]); sys.exit()
d=json.loads(r["content"][0]["text"])
rows=d.get("results",[])
print(str(len(rows))+" open; active=" + ", ".join(x["name"]+("*" if x.get("isModified") else "") for x in rows if x.get("isActive")))
' 2>/dev/null)
case "$docs" in
  ERROR*|"") warn "Document query failed: ${docs:-no response} (Fusion on the Home screen, or a modal dialog is open?)";;
  0\ open*)  warn "No document open — tools that need an active design will fail until one is created";;
  *)         pass "Documents: $docs";;
esac

# 7. Is this server registered with Claude Code?
if command -v claude >/dev/null; then
  reg=$(claude mcp get fusion 2>/dev/null)
  if grep -q "$url" <<<"$reg"; then
    pass "Claude Code has an MCP entry 'fusion' -> $url ($(grep -o 'Scope: [A-Za-z]*' <<<"$reg" | head -1))"
  elif [[ -n "$reg" && ! "$reg" =~ "No MCP server" ]]; then
    fail "Claude Code 'fusion' entry exists but does not point at $url"
    hint "claude mcp remove fusion; claude mcp add --transport http --scope user fusion $url"
  else
    fail "No 'fusion' MCP entry visible to Claude Code from $(pwd)"
    hint "claude mcp add --transport http --scope user fusion $url   (then restart the Claude session, or /mcp -> reconnect)"
  fi
fi

echo
if (( fail )); then echo "RESULT: FAIL"; exit 1; else echo "RESULT: OK"; fi
