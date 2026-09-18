#!/usr/bin/env bash
# The Playwright MCP server, over stdio, driving a HEADED Chromium on the
# virtual desktop whenever there is one.
#
# NOTHING MAY BE WRITTEN TO STDOUT.  stdout is the MCP transport: one stray
# echo is a protocol parse error, and Claude reports it as a broken server
# rather than as a chatty script.  Every diagnostic below goes to stderr, which
# Claude collects into the MCP log.
#
# WHY --browser chromium IS NOT OPTIONAL.  @playwright/mcp's default is the
# `chrome` CHANNEL -- system-installed Google Chrome -- and nothing here
# installs that; Google ships no arm64 Linux Chrome at all, so on an Apple
# Silicon host it could not be installed either.  `--browser chromium` selects
# the chrome-for-testing channel, which is the build `playwright install`
# downloaded at create, and is the same binary the human's `browser` runs.
#
# NEITHER HALF PASSES --no-sandbox, and for once that is the same decision
# reached twice rather than an inconsistency.  Playwright's own
# validateBrowserConfig sets chromiumSandbox=false on Linux for the
# chrome-for-testing channel, so the MCP browser runs unsandboxed whatever we
# do here -- `--no-sandbox` would be redundant, and passing it would hide the
# day that default changes.  The human's `browser` keeps the namespace sandbox
# on, because it works here (measured; see that script).  If you want the two
# to match, the lever is PLAYWRIGHT_MCP_ARGS below, not a flag added here.
set -uo pipefail

: "${DISPLAY:=:1}"
export DISPLAY
# See browser and desktop-svc.sh: the sandbox exports WAYLAND_DISPLAY=wayland-0
# into every process and Chromium believes it over $DISPLAY.
unset WAYLAND_DISPLAY
export XDG_SESSION_TYPE=x11

export PLAYWRIGHT_ROOT="${PLAYWRIGHT_ROOT:-/opt/playwright}"
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-$PLAYWRIGHT_ROOT/browsers}"
STATE="${BROWSER_STATE:-$HOME/.local/state/browser}"
PROFILE="${BROWSER_MCP_PROFILE:-$STATE/mcp-profile}"
CLI="$PLAYWRIGHT_ROOT/node_modules/@playwright/mcp/cli.js"

mkdir -p "$STATE" "$PROFILE" "$STATE/output"

if [[ ! -f $CLI ]]; then
    echo "[playwright-mcp] $CLI is missing -- the kit's install step did not complete." >&2
    exit 1
fi

# HEADED IF THERE IS A DISPLAY, HEADLESS IF THERE IS NOT, and the waiting in
# between is the part that matters.  This wrapper is spawned by Claude at
# session start; the desktop is a background startup command fired by a
# detached dispatcher at about the same moment, so on a cold create the X server
# is routinely a few seconds behind us.  Deciding immediately would mean an
# MCP server that silently chose headless for the whole session because it
# asked one second too early -- and the symptom of that is not an error, it is
# a human watching an empty desktop while the agent reports pages loading.
#
# So: only wait when there is something to wait FOR.  desktop-svc.sh existing is
# this kit's evidence that sbx-desktop is composed in -- a mixin cannot read the
# composition it is part of, and a file another kit ships is the honest proxy.
MODE=headless
if [[ -x /home/agent/bin/desktop-svc.sh ]]; then
    for _ in $(seq 1 60); do
        if xdpyinfo >/dev/null 2>&1; then MODE=headed; break; fi
        sleep 0.5
    done
    [[ $MODE == headed ]] \
        || echo "[playwright-mcp] the desktop kit is installed but $DISPLAY never came up in 30s; falling back to headless" >&2
elif xdpyinfo >/dev/null 2>&1; then
    # No desktop kit, but something is serving $DISPLAY anyway -- a
    # hand-started X server, or a socket bind-mounted in from another
    # container.  Use it.
    MODE=headed
fi

ARGS=(--browser chromium --user-data-dir "$PROFILE" --output-dir "$STATE/output")
[[ $MODE == headless ]] && ARGS+=(--headless)

echo "[playwright-mcp] $MODE, profile $PROFILE, browsers $PLAYWRIGHT_BROWSERS_PATH" >&2

# PLAYWRIGHT_MCP_ARGS is the escape hatch for everything this wrapper does not
# spell out -- --proxy-server=http://127.0.0.1:8080 to put the agent's browser
# through Burp, --device, --caps, --save-har.  Deliberately unquoted: it is a
# word-split argument list, not a single argument, and the alternative is a
# wrapper that grows a flag every time Playwright does.
# shellcheck disable=SC2086
exec node "$CLI" "${ARGS[@]}" ${PLAYWRIGHT_MCP_ARGS:-}
