#!/usr/bin/env bash
# The stdio MCP server Claude Code spawns: the node half of the staged Burp MCP
# server (upstream fwaeytens/burp-mcp-bridge, but stage-burp.sh can point at a
# fork, so nothing here may assume that repo beyond the two env vars below).
#
# NOTHING MAY EVER BE WRITTEN TO STDOUT HERE.  stdio is the MCP transport; a
# single stray line of output corrupts the protocol and the failure looks like a
# broken server, not a chatty script.  Diagnostics go to stderr only.
#
# MCP_TRANSPORT_MODE=stdio IS NOT A PREFERENCE.  The server defaults to `both`,
# which serves stdio AND opens an HTTPS/SSE listener on port 3000.  Two ways
# that bites: anything on that path which prints to stdout corrupts this
# transport, and a second Claude session in the same sandbox spawns a second
# server that collides on 3000.  Claude Code connects over stdio, so the other
# half is pure liability.  MCP_TRANSPORT_MODE and BURP_MCP_SERVER_PORT are
# upstream's own spellings; a fork that renames them breaks this wrapper.
#
# WAITING IS CONDITIONAL, NOT UNCONDITIONAL.  Burp starts on demand, so most
# sessions begin with no Burp at all and a fixed wait would stall every one of
# them at startup.  A Burp JVM that is up but not yet answering on 8081 is still
# loading its extension, and that IS worth waiting for.
#
# AND IT EXECS EITHER WAY.  A server that starts and returns a connection error
# per call leaves the tools listed and the error legible; a wrapper that exits
# instead leaves Claude with "server failed", no tools at all, and a mandatory
# /mcp after every Burp start.
set -uo pipefail

DIST=${BURP_DIST:-/opt/burp/dist}
# Installed at create by the kit, NOT staged: $DIST holds only the extension
# jar now. entry.js is a symlink the install hook points at whichever entry
# point it ended up with (source layout, or a published package's bin).
SERVER=${BURP_MCP_SERVER:-/opt/burp-mcp-server/entry.js}
PORT=${BURP_API_PORT:-8081}

export MCP_TRANSPORT_MODE=stdio
export BURP_MCP_SERVER_PORT="$PORT"

if [ ! -f "$SERVER" ]; then
    echo "[burp-mcp] no MCP server at $SERVER -- its create-time install did not run" >&2
    echo "[burp-mcp] or failed. Recreate the sandbox and watch for npm errors; the" >&2
    echo "[burp-mcp] source is the sbx-burp kit args burp_mcp_src / burp_mcp_pkg." >&2
    exit 1
fi

# THE TWO HALVES CAN DRIFT NOW, so say so rather than letting it surface as a
# tool that half works. The jar is staged on the host by stage-burp.sh and the
# node half is installed here at create, from coordinates given to two
# different commands; nothing makes them agree. Only source-mode installs are
# comparable -- a published package and a jar ref are not the same kind of
# thing, and a hand-built jar records no provenance at all.
staged="$DIST/burp-mcp-server.src"
mine="$(dirname "$SERVER")/.src"
if [ -r "$staged" ] && [ -r "$mine" ] && ! grep -q '^pkg ' "$mine" 2>/dev/null; then
    if [ "$(cat "$staged")" != "$(cat "$mine")" ]; then
        echo "[burp-mcp] WARNING: version drift between the two halves." >&2
        echo "[burp-mcp]   extension jar staged from: $(cat "$staged")" >&2
        echo "[burp-mcp]   node half installed from:  $(cat "$mine")" >&2
        echo "[burp-mcp] Re-stage or recreate with matching --burp-mcp-src." >&2
    fi
fi

open() { timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$PORT" 2>/dev/null; }

if ! open; then
    if pgrep -f 'burpsuite_pro\.jar' >/dev/null 2>&1; then
        echo "[burp-mcp] Burp is starting; waiting for the extension on :$PORT" >&2
        for _ in $(seq 1 120); do open && break; sleep 1; done
    else
        echo "[burp-mcp] Burp is not running; tool calls will fail until: burp-start.sh" >&2
    fi
fi

exec node "$SERVER"
