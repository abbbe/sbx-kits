#!/usr/bin/env bash
# Start Burp Suite Professional on the virtual desktop, on demand.
#
# ON DEMAND, NOT SUPERVISED, AND THAT IS DELIBERATE.  Burp is a 2-4GB JVM that
# most sessions in this sandbox do not want, and a mixin cannot raise the
# sandbox's memory limit (only `sbx run -m` can).  So there is no startup entry
# and no restart loop: you start it when you need it, and if it dies you find
# out from burp.log rather than from a supervisor quietly relaunching it.
#
# THE UPSTREAM PROXY IS THE WHOLE BALL GAME.  Every sbx sandbox has HTTPS_PROXY
# set and sbx terminates TLS with its own certificate; bypassing it with
# NO_PROXY yields EOF because the policy drops the direct connection (measured,
# see abbbe/sbx-workspace README).  A JVM ignores HTTP_PROXY/HTTPS_PROXY
# entirely, so without the upstream-proxy block written into Burp's user config
# below, EVERY request Burp sends fails -- with an error that names nothing
# relevant.  If you change one thing in this file, do not change that.
set -uo pipefail

DIST=${BURP_DIST:-/opt/burp/dist}
JAR="$DIST/burpsuite_pro.jar"

# EVERYTHING WRITABLE IS CONTAINER-LOCAL, AND THAT IS THE POINT.  $DIST is a
# read-only mount of host-staged artefacts and it is the ONLY thing this kit
# shares between sandboxes.
#
# It did not used to be.  There was a second mount, $BURP_STATE, read-write and
# pointed at ONE host directory by every sandbox at once, holding the Java
# preferences, the unpacked Burp installation and a single project.burp.  Three
# things followed, all bad:
#
#   * ONE PROJECT FILE FOR EVERY ENGAGEMENT.  A brand-new sandbox opened the
#     previous target's proxy history, sitemap and Repeater tabs, and wrote its
#     own traffic back into the same file.  Cross-engagement data bleed by
#     default, and any sandbox could read every other sandbox's captured
#     traffic.
#   * A WRITABLE, SHARED BURP INSTALLATION.  ~950MB of executable code, mounted
#     read-write into every sandbox, and launched by all of them.  Anything that
#     got code execution in one sandbox could rewrite the Burp that every other
#     sandbox then ran.
#   * A LOCK FIGHT.  Two sandboxes up at once contended for the same project
#     file.
#
# So there is no state mount now.  Preferences, the installation, logs and the
# rendered configs all live under $HOME, inside this container, and die with it.
# What survives a recreate is what the HOST staged into $DIST -- and it survives
# by being COPIED IN at create (see spec.yaml), never by being mounted writable.
STATE="${BURP_STATE:-$HOME/.local/state/burp}"

# Burp's Java preferences: the EULA acceptance, the licence, the activation
# record and Burp's CA.  Container-local, seeded at create from
# $DIST/prefs.xml when the host staged one.
PREFS_ROOT="$HOME/.java"

# PIN JAVA 21 IF IT IS THERE.  The kit installs openjdk-21-jre, but the base
# template already carries openjdk-25, which wins the `java` alternative -- and
# Burp then prints "Your JRE appears to be version 25.0.4 from Ubuntu. Burp has
# not been fully tested on this platform and you may experience problems."
# Measured in a live sandbox.  Java 21 is PortSwigger's stated minimum and the
# version their own builds ship, so prefer it explicitly rather than inheriting
# whatever the alternatives system picked.
JAVA=$(ls -d /usr/lib/jvm/java-21-openjdk-*/bin/java 2>/dev/null | head -1)
[ -x "${JAVA:-}" ] || JAVA=$(command -v java)
PROXY_PORT=${BURP_PROXY_PORT:-8080}
API_PORT=${BURP_API_PORT:-8081}
# THE EXTENSION READS THIS, AND IT READS NOTHING ELSE.  Without the export,
# BURP_API_PORT configured only the two clients -- this script's probe and
# burp-mcp.sh -- while the extension inside Burp bound its own compiled-in
# default. Setting BURP_API_PORT to anything but 8081 therefore broke the
# pairing silently, and it worked at all only because both sides independently
# said 8081. BURP_MCP_SERVER_PORT is fwaeytens' spelling (the extension also
# accepts -Dburp.mcp.server.port); an MCP server that reads neither binds
# whatever it defaults to, and BURP_MCP_WAIT=0 below is then the honest setting.
export BURP_MCP_SERVER_PORT="$API_PORT"
LOG="$STATE/burp.log"

: "${DISPLAY:=:1}"
export DISPLAY
# See desktop-svc.sh: sbx exports WAYLAND_DISPLAY=wayland-0 into every process
# and some toolkits treat that alone as proof of a Wayland session.
unset WAYLAND_DISPLAY

die() { echo "burp-start: $*" >&2; exit 1; }

port_open() { timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null; }

# --- 1. Refuse to double-start -------------------------------------------
# A second Burp loses the race for port 8080 and reports it as its own failure,
# which reads as "Burp is broken" rather than "Burp is already running".
#
# THE PORT IS THE AUTHORITY HERE, NOT THE PROCESS TABLE.  This was a pgrep
# alone, matching '[b]urpsuite_pro\.jar|[B]urpSuite' -- and it MISSED the
# flavour this kit goes out of its way to prefer.  An install4j launcher execs
# its bundled JRE, so the launcher's own name is gone from argv by the time
# anything can look for it.  Measured on a live sandbox, with Burp holding both
# ports, the process is:
#   .../burp/install/jre/bin/java -splash:.../.install4j/... --add-opens ...
# and BOTH old patterns scored zero.  So the one guard whose job is to stop a
# second Burp never fired for an installer-based Burp at all.
#
# Contending for the port is the actual failure mode, so test the port.  pgrep
# survives only to name a pid in the message, with the install directory this
# script itself chooses ($INSTALL_DIR) added to the pattern.  The
# brackets stop pgrep matching the shell running this very script, whose own
# command line would otherwise contain the pattern.
if port_open "$PROXY_PORT"; then
    pid=$(pgrep -f '[b]urpsuite_pro\.jar|[B]urpSuite|[b]urp-install' | head -1)
    if [ -n "$pid" ]; then
        echo "Burp is already running (pid $pid)."
    else
        echo "Something already holds port $PROXY_PORT; not starting a second Burp."
    fi
    echo "  proxy :$PROXY_PORT  mcp api :$API_PORT   log: $LOG"
    exit 0
fi

# --- 2. Validate the staging ----------------------------------------------
# This is the most likely misconfiguration in the whole kit, so it gets the
# best error message in it.
if [ ! -f "$JAR" ] && [ ! -f "$DIST/burp-installer.sh" ]; then
    cat >&2 <<EOF
burp-start: no Burp at $DIST (looked for burpsuite_pro.jar and burp-installer.sh)

Burp and the Burp MCP server are staged on the HOST and mounted in; not part
of this kit (PortSwigger's download needs your account, so nothing here can fetch
it for you).

On the host, once -- prefer the platform installer, which is the only flavour
that carries Burp's embedded browser for this architecture:
    ./kits/burp/stage-burp.sh --installer /path/to/burpsuite_pro_linux_arm64_v2026_8.sh

Then recreate the sandbox with the mount and the matching kit arg, e.g.
    sbx run --detached claude --name burpbox . \\
        \$HOME/.sbx/burp/dist:ro \\
        --kit .../kits/jupyter --kit .../kits/desktop --kit .../kits/burp \\
        --kit-arg sbx-burp.dist=\$HOME/.sbx/burp/dist \\
        -m 8g -p 8888:8888 -p 6080:6080 -p 8080:8080

An additional workspace mounts at its IDENTICAL host path, and the kit has no
way to read the mount table -- which is why the same path is typed twice.
$DIST is mounted :ro and there is no second, writable mount: nothing this
sandbox does to Burp can reach another sandbox.

Currently: BURP_DIST=$DIST
EOF
    exit 1
fi
mkdir -p "$STATE" || die "cannot create $STATE"

# --- 2b. Prefer a PortSwigger installation over the standalone jar ---------
# THE STANDALONE JAR HAS NO BROWSER ON THIS ARCHITECTURE.  Measured: the jar's
# chromium.properties declares a build for every platform including
# linuxarm64=151.0.7922.137, but the jar only *contains*
# chromium-{linux64,macosx64,win64}-*.zip.  StandaloneJarChromiumBinaryInstaller
# resolves that archive with getSystemResourceAsStream -- a CLASSPATH lookup
# inside the jar, not a download -- so on aarch64 it asks for
# chromium-linuxarm64-151.0.7922.137.zip, does not find it, and Burp's browser
# fails with no network traffic at all and nothing in the log.  That is why
# "Burp's browser failed to start" showed no blocked hosts and no
# ~/.BurpSuite/pre-wired-browser directory.
#
# PortSwigger's platform installers take the other code path
# (Install4JChromiumBinaryInstaller reading the browser out of the installation
# directory) and DO ship the arm64 build.  They also bundle PortSwigger's own
# JRE, which is what silences "Your JRE appears to be version ... from Ubuntu".
#
# So: if an installer has been staged, use it.
#
# THE INSTALL LANDS INSIDE THIS CONTAINER, AND IT IS PAID FOR ONCE PER SANDBOX.
# It used to land on the shared read-write state mount, which made it free after
# the first sandbox -- and also made ~950MB of executable code writable by every
# sandbox and executed by all of them.  That trade is not worth it: a few
# minutes and ~950MB at first start buys an installation no other sandbox can
# touch.  Use --jar staging instead if you would rather not pay it; the jar runs
# straight off the read-only mount, at the cost of Burp's embedded browser on
# arm64.
#
# WHAT THE ~950MB ACTUALLY IS, measured on an installed v2026.8 arm64 tree:
#   641MB  burpbrowser/<version>/   Burp's embedded Chromium
#   154MB  burpsuite.jar            Burp itself
#   141MB  jre/                     PortSwigger's bundled JRE
# All three are identical byte-for-byte across sandboxes built from the same
# installer, so the duplication is a candidate for block-level dedup on the host
# (or a shared READ-ONLY layer) rather than for another writable shared mount.
# Deliberately not done here: a GB per sandbox is the cheap side of that trade,
# and nothing writable goes back to being shared to save it.
INSTALL_DIR="$HOME/.local/share/burp/install"
INSTALLER="$DIST/burp-installer.sh"

# The install drops BurpSuite, BurpSuite.vmoptions and a .desktop file side by
# side, so match on EXECUTABILITY rather than on the glob order -- a plain
# `head -1` would happily hand back BurpSuite.vmoptions.
resolve_launcher() {
    LAUNCHER=""
    local c
    for c in "$INSTALL_DIR"/BurpSuite*; do
        if [ -f "$c" ] && [ -x "$c" ]; then LAUNCHER="$c"; return 0; fi
    done
    return 1
}

if ! resolve_launcher && [ -f "$INSTALLER" ]; then
    echo "[burp-start] installing Burp into $INSTALL_DIR (once; this takes a few minutes)"
    # install4j unattended flags: -q is unattended, -dir only valid with -q,
    # -console makes it report progress instead of running mute.
    sh "$INSTALLER" -q -dir "$INSTALL_DIR" -overwrite -console 2>&1 | sed 's/^/[installer] /'
    resolve_launcher || die "installer finished but no BurpSuite* launcher under $INSTALL_DIR"
    echo "[burp-start] installed: $LAUNCHER"
fi

# Build the command prefix once; everything below launches "${BURP[@]}" plus the
# project/config arguments, whichever flavour we ended up with.
if resolve_launcher; then
    # An install4j launcher takes JVM options from INSTALL4J_ADD_VM_PARAMS, not
    # from its argv, and uses the JRE bundled beside it rather than $JAVA.
    export INSTALL4J_ADD_VM_PARAMS="-XX:MaxRAMPercentage=50 -Djava.util.prefs.userRoot=$PREFS_ROOT -Dawt.useSystemAAFontSettings=on -Dswing.aatext=true"
    BURP=("$LAUNCHER")
elif [ -f "$JAR" ]; then
    BURP=("$JAVA"
          -XX:MaxRAMPercentage=50
          -Djava.util.prefs.userRoot="$PREFS_ROOT"
          -Dawt.useSystemAAFontSettings=on -Dswing.aatext=true
          -jar "$JAR")
    echo "[burp-start] using the standalone jar; Burp's embedded browser will not" >&2
    echo "[burp-start] work on $(uname -m). Stage a platform installer to get it:" >&2
    echo "[burp-start]   stage-burp.sh --installer <burpsuite_pro_linux_arm64_*.sh>" >&2
fi

# --- 3. The Java preferences store ----------------------------------------
# A PLAIN DIRECTORY IN THIS CONTAINER.  It was a symlink to the shared state
# mount, which is how the EULA acceptance and the licence activation survived
# `sbx rm` -- and also how every sandbox came to share one CA private key and
# one set of Burp preferences.
#
# What survives a recreate now is whatever the host staged: spec.yaml copies
# $DIST/prefs.xml in at create, so the EULA and the activation arrive already
# answered without anything being mounted writable.  Activations are a finite
# resource, so if this sandbox is the one that activates, harvest it back to the
# host afterwards and every later sandbox starts already licensed:
#
#     kits/burp/stage-burp.sh --harvest <sandbox-name>
#
# The launch line still passes -Djava.util.prefs.userRoot at the same path the
# JDK would default to, so it lands here whether or not the JRE honours it.
if [ -L "$PREFS_ROOT" ]; then
    die "$PREFS_ROOT is a symlink (a leftover of the old shared state mount); remove it"
fi
mkdir -p "$PREFS_ROOT"

# --- 4. Wait for the display ----------------------------------------------
# This bounded wait, and the message under it, ARE the entire dependency
# mechanism between this kit and sbx-desktop.  There is no kit-to-kit
# dependency machinery, and none is needed as long as the failure names the
# missing kit instead of surfacing as a HeadlessException from the JVM.
for _ in $(seq 1 60); do
    xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && break
    sleep 0.5
done
xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 || die \
    "no X display on $DISPLAY after 30s -- was this sandbox created with --kit .../kits/desktop ?"

# --- 5. Seed the configs, once, into the writable state -------------------
# BURP WRITES THE USER CONFIG BACK.  Whatever you change in the GUI is saved to
# the path given by --user-config-file when Burp exits, which is why it must be
# the copy under $STATE and never the kit's own seed (nor anything under $DIST,
# which is mounted read-only: Burp would fail to save mid-session and silently
# lose the extension registration).
#
# ONLY THE USER CONFIG IS PASSED ON THE LAUNCH LINE.  project-config.json is
# rendered here and then left alone: it is a PROJECT option set, and which
# project this sandbox opens is your call, made in Burp's own project dialog
# (see step 7).  Select it there under "Load from configuration file" if you
# want it; its path is printed at the end of this script.
#
# The upside of that write-back is that it makes this kit self-improving: set
# something in the GUI once, then `stage-burp.sh --reseed` copies the result
# back over the seeds. That is also how to harvest the config keys nobody has
# documented -- toggle, diff, commit.
render() {
    python3 - "$1" "$2" "${3:-}" <<'PY'
import json, os, sys
src, dst = sys.argv[1], sys.argv[2]
raw = open(src).read().replace("@BURP_DIST@", os.environ["DIST"])
cfg = json.loads(raw)

# EXTENSIONS ARE CONTRIBUTED, NOT WRITTEN INTO THE SEED.  The seed ships an
# empty extension list and every entry arrives as a file in extensions.d, so
# "which MCP server is loaded" stops being a fact baked into this kit's Burp
# configuration. Anything that wants an extension -- a different MCP server, a
# BApp you keep locally, a second kit -- drops a .json in and changes nothing
# else. Same seam as the desktop kit's fluxbox menu.d.
#
# Fragments are read in filename order, each one either an object or a list of
# them, with @BURP_DIST@ expanded exactly as in the seed.
ext_dir = sys.argv[3] if len(sys.argv) > 3 else ""
if ext_dir and os.path.isdir(ext_dir):
    frags = []
    for name in sorted(os.listdir(ext_dir)):
        if not name.endswith(".json"):
            continue
        text = open(os.path.join(ext_dir, name)).read()
        text = text.replace("@BURP_DIST@", os.environ["DIST"])
        loaded = json.loads(text)
        frags.extend(loaded if isinstance(loaded, list) else [loaded])
    if frags:
        ext = cfg.setdefault("user_options", {}).setdefault("extender", {})
        ext.setdefault("extensions", []).extend(frags)
        print("[burp-start] %d extension(s) from %s" % (len(frags), ext_dir),
              file=sys.stderr)

# Fill the upstream proxy from the sandbox's own HTTPS_PROXY, or remove the
# block entirely when there is none -- an upstream proxy pointing at a host
# that is not there is worse than no upstream proxy at all.
px = os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy") or ""
srv = cfg.get("user_options", {}).get("connections", {}).get("upstream_proxy", {})
if "servers" in srv:
    if px:
        hostport = px.split("://", 1)[-1].rstrip("/")
        host, _, port = hostport.rpartition(":")
        if not host:
            host, port = hostport, "8080"
        for s in srv["servers"]:
            if s.get("proxy_host") == "@PROXY_HOST@":
                s["proxy_host"] = host
                s["proxy_port"] = int(port)
    else:
        srv["servers"] = []
        print("[burp-start] HTTPS_PROXY is unset; assuming direct egress", file=sys.stderr)

json.dump(cfg, open(dst, "w"), indent=2)
PY
}

export DIST
for f in user-config project-config; do
    [ -e "$STATE/$f.json" ] && continue
    # extensions.d belongs to the user config only; project-config has no
    # extender section and passing it one would invent a key Burp did not ask
    # for.
    extdir=""
    [ "$f" = user-config ] && extdir="$HOME/etc/burp/extensions.d"
    render "$HOME/etc/burp/$f.seed.json" "$STATE/$f.json" "$extdir" \
        || die "could not render $f.json"
    echo "[burp-start] seeded $STATE/$f.json"
done

# --- 6. First run needs a TERMINAL, not a detached process ----------------
# BURP'S FIRST RUN IS A CONSOLE CONVERSATION, NOT A GUI WIZARD.  With an empty
# Java preferences store it prints the whole EULA to stdout and blocks on
# "Do you accept the license agreement? (y/n)" from STDIN -- before it opens a
# window, binds a port, or loads an extension.  The licence key prompt follows
# the same way.
#
# Measured: launched detached, with stdin not a terminal, Burp printed the EULA
# into burp.log, read EOF, and exited. Nothing on the desktop, nothing on 8080,
# and the only evidence was 70KB of licence text in the log. That is why this
# refuses to detach on a first run instead of reproducing that silence.
#
# Once accepted, `burp.eula` lands in the prefs store.  That store is
# container-local now, so WITHOUT a staged $DIST/prefs.xml this branch is taken
# once per sandbox -- and each of those runs spends one licence activation.
# Answer the prompts in the first sandbox, then
#     kits/burp/stage-burp.sh --harvest <sandbox-name>
# copies the answers to the host, and every later sandbox has them copied in at
# create and starts detached and silent.
# DO NOT HARDCODE THE PREFS PATH.  An earlier version probed
# $PREFS_ROOT/.userPrefs/burp/prefs.xml, which is where the JDK default and
# -Djava.util.prefs.userRoot both say it should be -- and it is where the
# INSTALLER's own prefs land ($PREFS_ROOT/.userPrefs/com/install4j/...).  Burp
# itself writes ONE LEVEL DEEPER: measured, the accepted EULA is at
# $PREFS_ROOT/.java/.userPrefs/burp/prefs.xml, so the two JVMs involved disagree
# about the root and the hardcoded path matched neither reliably.  That is also
# why stage-burp.sh --harvest finds the file by grepping for burp.eula rather
# than by path, and why spec.yaml seeds it at the deeper of the two.
#
# The cost of getting this wrong is invisible and permanent: the probe fails
# forever, so EVERY start takes the interactive first-run branch below, sits in
# the foreground streaming Burp's log to the terminal, and waits for an EULA
# prompt that will never come because Burp is already licensed.  Searching the
# prefs tree for the key is immune to which root the JRE picked.
if ! grep -rq --include=prefs.xml 'burp\.eula' "$PREFS_ROOT" 2>/dev/null; then
    if [ ! -t 0 ]; then
        cat >&2 <<EOF
burp-start: this is Burp's first run against $PREFS_ROOT, and it will ask you to
accept the EULA (and then for your licence key) ON THE TERMINAL. Detaching now
would just block on a closed stdin and exit.

(If you have already answered these in another sandbox, you should not be seeing
this: harvest that sandbox's answers to the host with stage-burp.sh --harvest
and recreate this one, rather than spending a second activation.)

Re-run it attached to a terminal:

    sbx exec -it $(hostname) /home/agent/bin/burp-start.sh

Your licence key is at $DIST/license.key. Answer the prompts once; the answers
are stored in $PREFS_ROOT, which belongs to THIS sandbox and dies with it -- run
stage-burp.sh --harvest on the host afterwards to keep them.
EOF
        exit 1
    fi

    echo "[burp-start] first run: answer the EULA and licence prompts below."
    echo "[burp-start] licence key: $DIST/license.key"
    echo

    # THE REDIRECT IS SET UP BEFORE THE exec, NOT PIPED INTO IT.  Written the
    # obvious way -- `exec "${BURP[@]}" ... 2>&1 | tee -a "$LOG"` -- the exec is
    # one element of a PIPELINE, so it replaces the subshell bash forked for that
    # element and NOT this script.  The script then survives Burp, falls through
    # to the detached launch in step 7, and starts a SECOND Burp the moment the
    # foreground one exits or is interrupted.  Measured: ^C on the first run
    # printed "launching Burp" and brought up another instance.
    #
    # Process substitution keeps the log without putting exec in a pipeline, so
    # this really is the last thing the script does.
    exec > >(tee -a "$LOG") 2>&1
    exec "${BURP[@]}" --user-config-file="$STATE/user-config.json"
fi

# --- 7. Launch detached ---------------------------------------------------
# setsid nohup is not decoration.  `sbx exec <sandbox> burp-start.sh` tears down
# its process group when the exec returns, and without this Burp dies the
# instant the command that started it finishes.
#
# -XX:MaxRAMPercentage=50 rather than -Xmx: it is what PortSwigger's own
# vmoptions.txt ships, and the JVM reads the cgroup limit, so it tracks
# `sbx run -m 8g` without this kit having to know the number.
#
# No --use-defaults: it means "ignore saved configuration", which would discard
# the very files seeded above.  No --unpause-spider-and-scanner: auto-starting a
# scanner whose targets an LLM chooses is not a shippable default.
# NO --project-file, AND THAT IS DELIBERATE.  Passing one made this script
# decide, on your behalf and identically for every sandbox, which project Burp
# opened -- and because it named a path on a shared mount, every sandbox opened
# the SAME project and inherited the previous engagement's proxy history.
#
# Which project to open is a per-sandbox decision and it is yours: without the
# flag Burp shows its own project dialog on the desktop -- temporary project,
# new project on disk, or open an existing one -- and waits there until you
# choose.  Step 8 below expects that wait rather than treating it as a failure.
#
# --config-file goes with it, for the same reason: a project configuration
# applies to a project this script no longer picks.  It is still rendered (step
# 5) and you can select it in that dialog.
echo "[burp-start] launching Burp (log: $LOG)"
setsid nohup "${BURP[@]}" \
    --user-config-file="$STATE/user-config.json" \
    >>"$LOG" 2>&1 &

# --- 8. Wait for the proxy, or explain the failure ------------------------
# ONLY THE PROXY IS WAITED ON HERE, and that is a deliberate narrowing.  This
# loop used to require the MCP API too, which made starting Burp depend on a
# port belonging to a different component: against an MCP server that speaks
# stdio inside the JVM, or over a unix socket, that port never opens and this
# sat for the full 120 seconds before reporting a failure that had not
# happened. The proxy is what this script owns; the MCP side gets a bounded,
# advisory probe below, and burp-mcp.sh waits again at the point it matters.
# A TIMEOUT HERE IS NOT NECESSARILY A FAILURE ANY MORE.  With no --project-file
# Burp binds nothing until you pick a project in its dialog, so the proxy can
# legitimately stay shut for as long as it takes you to walk to the desktop.
# Distinguishing "the JVM died" from "the JVM is waiting for you" is the whole
# job of this step: the first is an error, the second is the normal path.
echo "[burp-start] Burp is asking which project to open -- choose one on the desktop:"
echo "[burp-start]   $("$HOME/bin/desktopctl" url 2>/dev/null || echo '~/bin/desktopctl url')"
echo "[burp-start] (a temporary project is the right answer unless you want this"
echo "[burp-start]  engagement's history on disk; it is this sandbox's disk either way)"
for _ in $(seq 1 120); do
    port_open "$PROXY_PORT" && break
    sleep 1
done

if ! port_open "$PROXY_PORT"; then
    if pgrep -f '[b]urpsuite_pro\.jar|[B]urpSuite|[b]urp-install' >/dev/null; then
        echo
        echo "Burp is running but has not opened the proxy yet -- it is still on the"
        echo "project dialog. Choose a project on the desktop; the listener binds then."
        echo "  log: $LOG"
        exit 0
    fi
    echo "burp-start: Burp exited without opening port $PROXY_PORT. Last 20 lines of $LOG:" >&2
    tail -n 20 "$LOG" >&2
    # The generic form of this reads as a crash and sends people to the wrong
    # place, so name it: 137 is the container OOM killer, not a Burp bug.
    echo "(if the JVM vanished with rc=137 it was the OOM killer: raise sbx run -m)" >&2
    exit 1
fi

# ADVISORY, BOUNDED, AND SKIPPABLE.  Extensions load after the proxy listener
# binds, so a single probe here would report "not up" on a healthy start; a
# wait is needed, but it must not be this script's definition of success.
# BURP_MCP_WAIT=0 turns it off, which is the right setting for an MCP server
# that binds no TCP port at all.
case "${BURP_MCP_WAIT:-30}" in
    ""|*[!0-9]*) MCP_WAIT=30 ;;
    *)           MCP_WAIT=${BURP_MCP_WAIT:-30} ;;
esac
if [ "$MCP_WAIT" -gt 0 ]; then
    for _ in $(seq 1 "$MCP_WAIT"); do
        port_open "$API_PORT" && break
        sleep 1
    done
    if ! port_open "$API_PORT"; then
        echo "burp-start: proxy is up but the MCP server API on $API_PORT is not." >&2
        echo "  The extension may not have loaded -- check Extensions in the Burp UI." >&2
        echo "  Its entry is rendered into $STATE/user-config.json once, from the" >&2
        echo "  fragments in $HOME/etc/burp/extensions.d; a stale user-config.json" >&2
        echo "  from before that mechanism still carries its own extension_file path." >&2
        echo "  If this MCP server binds no port, set BURP_MCP_WAIT=0." >&2
    fi
fi

# --- 9. Trust Burp's CA inside the sandbox --------------------------------
# The trust store is container overlay, so this has to run in every new
# container even though the CA itself (living in the Java prefs on the state
# mount) is stable across recreates.
#
# System-wide trust is safe HERE because there is no global proxy: trusting a
# CA redirects nothing by itself, and only `via-burp` sends traffic somewhere
# that trust applies.  Same pairing as -ac with -nolisten tcp in desktop-svc.sh.
CA=/usr/local/share/ca-certificates/burp.crt
if [ ! -s "$CA" ]; then
    if curl -fsS "http://127.0.0.1:$PROXY_PORT/cert" -o /tmp/burp.der 2>/dev/null &&
       openssl x509 -inform der -in /tmp/burp.der -out /tmp/burp.crt 2>/dev/null; then
        sudo install -m 0644 /tmp/burp.crt "$CA" && sudo update-ca-certificates >/dev/null 2>&1 \
            && echo "[burp-start] installed Burp's CA into the system trust store"
    else
        echo "[burp-start] could not fetch Burp's CA yet; re-run this script once the UI is up" >&2
    fi
fi

echo
echo "Burp is up.  proxy :$PROXY_PORT   mcp api :$API_PORT   log: $LOG"
echo "  desktop:  $("$HOME/bin/desktopctl" url 2>/dev/null || echo '~/bin/desktopctl url')"
echo "  route a command through it:  via-burp curl -sS https://target/"
echo "  project config to select in Burp's dialog, if you want it:"
echo "      $STATE/project-config.json"
echo "  this sandbox's Burp state is local to it and is NOT shared with any other"
echo "  sandbox; it goes away with \`sbx rm\`."
