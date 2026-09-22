#!/usr/bin/env bash
# Stage Burp Pro and the Burp MCP server on the HOST, for mounting into a sandbox.
#
# This runs on your machine, not in the sandbox, and it is deliberately NOT
# under files/ so it never gets shipped into one.  It works the same on macOS
# and Linux: nothing here looks in /Applications or anywhere else macOS-specific.
#
# WHY STAGING AT ALL, RATHER THAN DOWNLOADING AT CREATE.  portswigger.net is
# the last host you want reachable from a sandbox that renders
# attacker-controlled responses, and staging keeps it off the allowlist.  And a
# ~400MB download on every `sbx create` is a tax with no upside, since the jar
# changes monthly at most.
#
# WHAT THIS DIRECTORY IS NOT.  It is mounted READ-ONLY into every sandbox, and
# it holds only artefacts: the Burp installer or jar, the MCP extension jar, the
# licence key, and -- once you have harvested it -- prefs.xml.  It holds NO
# project files and no live Burp state.  There used to be a sibling `state/`
# directory mounted read-write into every sandbox at once, and it meant a fresh
# sandbox opened the previous engagement's proxy history while every sandbox
# could rewrite the Burp binary the others ran.  Do not reintroduce it.
#
# WHY THE BURP JAR IS NOT DOWNLOADED HERE EITHER.  Measured: a GET of
# https://portswigger.net/burp/releases/download?product=pro&version=...&type=Jar
# from an unauthenticated client 302s to the marketing page and returns HTML.
# The Pro jar is behind your PortSwigger session, so no script can fetch it and
# this one does not pretend to.  You download it; --jar points at it.
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${HOME}/.sbx/burp"
# THE BURP MCP SERVER IS TWO HALVES, AND ONLY ONE OF THEM IS STAGED HERE.
# The extension jar is a Burp extension publishing a JSON-RPC API on
# 127.0.0.1:8081; the node half speaks MCP over stdio and calls that API.  The
# node half is NOT staged -- kits/burp/spec.yaml installs it inside the sandbox
# at create, so npm runs under the sandbox's egress policy rather than on your
# machine.  Only the jar is here, because Burp loads it from a file path and
# nothing in the sandbox builds Java.
#
# BURP_MCP_SRC is the same owner/repo@ref coordinate the kit arg takes, and the
# two must agree: the halves are versioned together and nothing enforces it
# across the two commands.  Staging writes the value into dist/ so burp-mcp.sh
# can warn when they drift.
BURP_MCP_SRC="fwaeytens/burp-mcp-bridge@v2.8.0"
BURP_MCP_JAR=""
JAR=""
INSTALLER=""
LICENSE_FILE=""
RESEED=""
HARVEST=""

usage() {
    cat <<EOF
Usage: $0 (--installer PATH | --jar PATH) [options]
       $0 --harvest SANDBOX [--root DIR]
       $0 --reseed  SANDBOX [--root DIR]

  --installer PATH       Burp Suite Professional PLATFORM INSTALLER (.sh) for
                         the sandbox's architecture. PREFER THIS: it is the only
                         flavour that carries Burp's embedded browser for arm64,
                         and it bundles PortSwigger's own JRE. Download it from
                         https://portswigger.net/burp/releases/ -- log in, pick
                         your version, platform "Linux (ARM)" on Apple Silicon
                         or "Linux (x64)" on an Intel host.
  --jar PATH             Burp Suite Professional standalone JAR. Works, but its
                         embedded browser is x64-only (the jar ships
                         chromium-{linux64,macosx64,win64} and nothing for
                         linuxarm64, despite declaring it in chromium.properties).
  --root DIR             Staging root (default: \$HOME/.sbx/burp)
  --burp-mcp-src OWNER/REPO@REF
                         Where the Burp MCP server's EXTENSION JAR comes from.
                         A vX.Y.Z ref names the release whose jar is fetched;
                         any other ref needs --burp-mcp-jar too, since nothing
                         here builds Java. Pass the SAME coordinate to the kit
                         (--burp-mcp-src on bin/sbx-kits) so both halves match.
                         (default: $BURP_MCP_SRC)
  --burp-mcp-jar PATH    Use this extension jar instead of a release asset --
                         what a fork on a branch needs. Build one from a
                         checkout with: mvn -f extension/pom.xml package
  --license-file FILE    File containing your Burp licence key (else prompted)
  --harvest SANDBOX      Copy Burp's accepted EULA and licence activation OUT of
                         a running sandbox into dist/prefs.xml, so every later
                         sandbox is created already licensed instead of spending
                         a fresh activation. Burp's CA is stripped on the way --
                         each sandbox mints its own rather than sharing one
                         private key across engagements. Run it once, after
                         answering the first-run prompts in the first sandbox.
  --reseed SANDBOX       Copy the live Burp configs out of a running sandbox
                         back over this kit's *.seed.json, re-parameterising
                         absolute paths. Run it after changing settings in the
                         Burp GUI.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --jar) JAR="${2:?}"; shift 2 ;;
        --installer) INSTALLER="${2:?}"; shift 2 ;;
        --root) ROOT="${2:?}"; shift 2 ;;
        --burp-mcp-src) BURP_MCP_SRC="${2:?}"; shift 2 ;;
        --burp-mcp-jar) BURP_MCP_JAR="${2:?}"; shift 2 ;;
        --license-file) LICENSE_FILE="${2:?}"; shift 2 ;;
        --harvest) HARVEST="${2:?}"; shift 2 ;;
        --reseed) RESEED="${2:?}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

die() { echo "stage-burp: $*" >&2; exit 1; }

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"
    else shasum -a 256 "$@"; fi
}

# --- harvest mode ---------------------------------------------------------
# THE REPLACEMENT FOR THE OLD SHARED STATE MOUNT, and the difference is that this
# is a deliberate, one-directional copy of a couple of facts rather than a live
# directory every sandbox writes to.
#
# What it takes: Burp's preferences file, carrying the accepted EULA
# (burp.eula), the licence (license1) and the opaque activation record
# PortSwigger hands back.  Those are what is expensive to redo -- activations are
# a finite resource, and re-activating once per sandbox eventually means a
# support ticket.  prune-prefs.py beside this script is where the rest of the
# file, Burp's CA above all, is dropped; read its docstring before changing it.
find_prefs() {
    # WHICH prefs.xml is not knowable from the outside: install4j's JVM treats
    # $HOME/.java as the preferences ROOT while Burp's own writes one level
    # deeper, so the file that matters is found by CONTENT, not by path.
    sbx exec "$1" bash -lc \
        'grep -rls --include=prefs.xml "burp\.eula" "$HOME/.java" 2>/dev/null | head -1'
}

if [ -n "$HARVEST" ]; then
    command -v sbx >/dev/null 2>&1 || die "no sbx on PATH; --harvest reads from a running sandbox"
    src=$(find_prefs "$HARVEST" | tr -d '\r')
    [ -n "$src" ] || die "no preferences with an accepted EULA in sandbox '$HARVEST'.
    Start Burp there and answer the first-run prompts first:
        sbx exec -it $HARVEST /home/agent/bin/burp-start.sh"
    mkdir -p "$ROOT/dist"
    tmp=$(mktemp)
    sbx exec "$HARVEST" cat "$src" > "$tmp" || die "could not read $src from '$HARVEST'"
    [ -s "$tmp" ] || die "$src came back empty"
    python3 "$KIT_DIR/prune-prefs.py" "$tmp" "$ROOT/dist/prefs.xml" || exit 1
    rm -f "$tmp"
    chmod 600 "$ROOT/dist/prefs.xml"
    echo "==> harvested $HARVEST:$src -> $ROOT/dist/prefs.xml"
    echo "    Sandboxes created from now on start with the EULA accepted and the"
    echo "    licence in place.  It is COPIED IN at create, never mounted: nothing"
    echo "    a sandbox does to its own preferences reaches this file, and no"
    echo "    sandbox can see another's."
    exit 0
fi

# --- reseed mode ----------------------------------------------------------
# Burp writes its user configuration back to the file given by
# --user-config-file.  So the way to preset a setting whose JSON key nobody has
# documented is: set it once in the GUI, then run this, then commit the diff.
# That is how the proxy listener spelling and Burp's "run the browser without a
# sandbox" toggle got captured, rather than guessed.
#
# IT READS FROM A SANDBOX, NOT FROM A HOST DIRECTORY.  These files used to sit on
# the shared read-write state mount, where this script could simply open them.
# There is no such mount now -- the live configs are inside whichever sandbox you
# were experimenting in -- so that sandbox has to be named.  Quit Burp there
# first: it writes the file on EXIT, so reseeding while it is running harvests
# the configuration you started with rather than the one you just set.
if [ -n "$RESEED" ]; then
    command -v sbx >/dev/null 2>&1 || die "no sbx on PATH; --reseed reads from a running sandbox"
    for f in user-config project-config; do
        live=$(mktemp)
        if ! sbx exec "$RESEED" cat "/home/agent/.local/state/burp/$f.json" >"$live" 2>/dev/null ||
           [ ! -s "$live" ]; then
            echo "stage-burp: no $f.json in sandbox '$RESEED' yet, skipping" >&2
            rm -f "$live"
            continue
        fi
        python3 - "$live" "$KIT_DIR/files/home/etc/burp/$f.seed.json" "$ROOT/dist" <<'PY'
import json, sys
live, seed, dist = sys.argv[1], sys.argv[2], sys.argv[3]
raw = open(live).read().replace(dist, "@BURP_DIST@")
cfg = json.loads(raw)
# The upstream proxy is per-sandbox, so put the placeholder back rather than
# baking one sandbox's egress proxy address into the kit.
srv = cfg.get("user_options", {}).get("connections", {}).get("upstream_proxy", {})
for s in srv.get("servers", []):
    s["proxy_host"] = "@PROXY_HOST@"
    s["proxy_port"] = 0
# EXTENSIONS ARE DROPPED ON THE WAY BACK IN.  A live user config lists every
# extension Burp had loaded, with absolute paths; copying that into the seed
# would re-bake one sandbox's jar path into the kit and silently undo
# extensions.d, which is where entries are supposed to come from. So reseed
# harvests settings and never extensions: to add one, write a fragment.
ext = cfg.get("user_options", {}).get("extender", {})
if ext.get("extensions"):
    print("  dropped %d extension entry(ies) -- those belong in "
          "files/home/etc/burp/extensions.d/" % len(ext["extensions"]))
    ext["extensions"] = []
json.dump(cfg, open(seed, "w"), indent=2)
open(seed, "a").write("\n")
print("reseeded %s" % seed)
PY
        rm -f "$live"
    done
    echo
    echo "Review with: git -C \"$KIT_DIR\" diff"
    exit 0
fi

# --- preflight ------------------------------------------------------------
# No node, no npm: the node half is installed in the sandbox now, so this script
# never runs a package manager and never builds anything for a platform it is
# not running on.  That is the whole point of moving it.
for c in curl tar unzip python3; do
    command -v "$c" >/dev/null 2>&1 || die "missing required tool: $c"
done

[ -n "$JAR" ] || [ -n "$INSTALLER" ] || {
    usage >&2; echo >&2; die "one of --installer (preferred) or --jar is required"; }

# dist/ ONLY, and it is mounted :ro.  There is no state/ any more: everything
# Burp writes belongs to one sandbox and is created inside it.  See the header.
mkdir -p "$ROOT/dist"

# The sandbox inherits the host's architecture, so the installer has to match
# this machine, not the machine the licence was bought on.
case "$(uname -m)" in
    arm64|aarch64) WANT_ARCH=arm64 ;;
    x86_64|amd64)  WANT_ARCH=x64 ;;
    *)             WANT_ARCH="" ;;
esac

# --- Burp platform installer (preferred) ----------------------------------
if [ -n "$INSTALLER" ]; then
    echo "==> Burp platform installer"
    [ -f "$INSTALLER" ] || die "no such file: $INSTALLER"
    # install4j installers are shell scripts with a payload appended. A partial
    # or wrong download surfaces much later as a hung install, so check now.
    # -i because the marker in the header is the uppercase INSTALL4J_* variable
    # names, not the lowercase product name.
    head -c 2048 "$INSTALLER" | grep -qi 'install4j' \
        || die "$INSTALLER does not look like an install4j installer"
    case "$(basename "$INSTALLER")" in
        *linux*|*Linux*) : ;;
        *) echo "    WARNING: '$(basename "$INSTALLER")' does not look like a LINUX build;" >&2
           echo "             the sandbox is Linux regardless of your host OS." >&2 ;;
    esac
    if [ "$WANT_ARCH" = arm64 ]; then
        case "$(basename "$INSTALLER")" in
            *arm64*|*aarch64*) : ;;
            *) echo "    WARNING: this host is arm64 but '$(basename "$INSTALLER")' does not" >&2
               echo "             look like an arm64 build. Burp will not start." >&2 ;;
        esac
    fi
    cp "$INSTALLER" "$ROOT/dist/burp-installer.sh"
    chmod +x "$ROOT/dist/burp-installer.sh"
fi

# --- Burp standalone jar (fallback) ---------------------------------------
if [ -n "$JAR" ]; then
    echo "==> Burp jar"
    [ -f "$JAR" ] || die "no such file: $JAR"
    # A truncated download or an HTML error page saved as a .jar is the classic
    # silent failure here, and it surfaces later as "Burp will not start".
    unzip -p "$JAR" META-INF/MANIFEST.MF 2>/dev/null | grep -q 'Main-Class: *burp\.StartBurp' \
        || die "$JAR does not look like a Burp jar (no Main-Class: burp.StartBurp)"
    cp "$JAR" "$ROOT/dist/burpsuite_pro.jar"
fi

# --- the Burp MCP server: the extension jar only ---------------------------
# The jar is a public GitHub release asset, so unlike the Burp jar it CAN be
# fetched -- on the host, because Burp loads the extension from a file path on
# the read-only dist mount.  Its other half, the node process, is not here: the
# kit installs it inside the sandbox at create.
#
# A REF WITH NO RELEASE BEHIND IT YIELDS NO JAR, because nothing here builds
# Java.  That is what --burp-mcp-jar is for: build it from your checkout
# (mvn -f extension/pom.xml package) and point at the result.
BURP_MCP_REPO="${BURP_MCP_SRC%@*}"
BURP_MCP_REF="${BURP_MCP_SRC##*@}"
SERVER_NAME="${BURP_MCP_REPO##*/}"

echo "==> $BURP_MCP_REPO $BURP_MCP_REF extension jar"
if [ -n "$BURP_MCP_JAR" ]; then
    [ -f "$BURP_MCP_JAR" ] || die "no such file: $BURP_MCP_JAR"
    cp "$BURP_MCP_JAR" "$ROOT/dist/burp-mcp-server.jar"
    echo "    from $BURP_MCP_JAR"
    # Deliberately no .src marker: a jar handed over as a file has no provenance
    # this script can record, so there is nothing honest to compare against.
    rm -f "$ROOT/dist/burp-mcp-server.src"
else
    case "$BURP_MCP_REF" in
        v*.*.*) : ;;
        *) die "'$BURP_MCP_REF' in --burp-mcp-src is not a vX.Y.Z release tag, so there is
    no release asset to fetch. Build the extension jar from that ref --
    mvn -f extension/pom.xml package -- and pass it with --burp-mcp-jar." ;;
    esac
    # Upstream's asset is named <repo>-<version>.jar; a fork whose release
    # workflow is inherited unchanged produces the same spelling.  If yours does
    # not, --burp-mcp-jar sidesteps this URL entirely.
    curl -fL --retry 3 -o "$ROOT/dist/burp-mcp-server.jar" \
        "https://github.com/${BURP_MCP_REPO}/releases/download/${BURP_MCP_REF}/${SERVER_NAME}-${BURP_MCP_REF#v}.jar"
    # WHAT THE JAR CAME FROM, for burp-mcp.sh to compare against what the kit
    # installed in the sandbox.  The two halves are versioned together and they
    # now arrive by two different routes, so drift is possible and silent.
    printf '%s\n' "$BURP_MCP_SRC" > "$ROOT/dist/burp-mcp-server.src"
fi
unzip -p "$ROOT/dist/burp-mcp-server.jar" META-INF/MANIFEST.MF >/dev/null 2>&1 \
    || die "$ROOT/dist/burp-mcp-server.jar has no manifest -- probably an HTML error page"

# --- licence key ----------------------------------------------------------
echo "==> licence key"
if [ -n "$LICENSE_FILE" ]; then
    [ -f "$LICENSE_FILE" ] || die "no such file: $LICENSE_FILE"
    cp "$LICENSE_FILE" "$ROOT/dist/license.key"
elif [ ! -s "$ROOT/dist/license.key" ]; then
    printf 'Paste your Burp licence key (input hidden): ' >&2
    read -rs key
    printf '\n' >&2
    [ -n "$key" ] || die "no licence key given"
    printf '%s' "$key" > "$ROOT/dist/license.key"
else
    echo "    keeping the existing $ROOT/dist/license.key"
fi
chmod 600 "$ROOT/dist/license.key"

# --- manifest -------------------------------------------------------------
( cd "$ROOT/dist" && sha256 burp-mcp-server.jar \
    $([ -f burpsuite_pro.jar ] && echo burpsuite_pro.jar) \
    $([ -f burp-installer.sh ] && echo burp-installer.sh) > MANIFEST.sha256 )

# --- what to run ----------------------------------------------------------
REPO_ROOT="$(cd "$KIT_DIR/../.." && pwd)"

cat <<EOF

Staged into $ROOT  (MCP extension jar: $BURP_MCP_SRC)
$([ -f "$ROOT/dist/burp-installer.sh" ] && printf '    dist/burp-installer.sh      %s (installed on first burp-start.sh)' "$(du -h "$ROOT/dist/burp-installer.sh" | cut -f1)")
$([ -f "$ROOT/dist/burpsuite_pro.jar" ] && printf '    dist/burpsuite_pro.jar      %s' "$(du -h "$ROOT/dist/burpsuite_pro.jar" | cut -f1)")
    dist/burp-mcp-server.jar    $(du -h "$ROOT/dist/burp-mcp-server.jar" | cut -f1)
    dist/license.key            (0600)
    state/                      empty until first run; holds the activation

The MCP server's node half is NOT staged. The kit installs it inside the sandbox
at create, so npm resolves and downloads under the sandbox's egress policy
instead of on this machine.$([ "$BURP_MCP_SRC" != "fwaeytens/burp-mcp-bridge@v2.8.0" ] && printf '\n\nYou staged a non-default jar, so pass the MATCHING coordinate at create or the\ntwo halves will be different versions:\n\n    %s/bin/sbx-kits up --burp-mcp-src %s' "$REPO_ROOT" "$BURP_MCP_SRC")

This script stages artefacts and stops there; creating and driving the sandbox
belongs to the wrapper, which owns the kit list, the mounts, the shared token and
the host ports:

    $REPO_ROOT/bin/sbx-kits up

    $REPO_ROOT/bin/sbx-kits status      # what is up
    $REPO_ROOT/bin/sbx-kits urls        # URLs and token again

First Burp start needs a terminal -- its EULA and licence prompts are a console
conversation, not a GUI wizard:

    sbx exec -it <name> /home/agent/bin/burp-start.sh

Your licence key is in $ROOT/dist/license.key -- inside the sandbox it is at
the same path, so you can cat it in a noVNC terminal and paste it into the
wizard.
EOF
