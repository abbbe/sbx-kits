# sbx-kits: JupyterLab, a desktop, and Burp Suite Pro

Three mixin kits for [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) (`sbx`),
composed onto the stock `claude` agent. Each one works alone; together they give a sandbox
where Claude drives Burp over MCP, you watch and click the real Burp GUI in a browser, and
JupyterLab is there for scripting.

| kit | what it adds | port | starts |
|---|---|---|---|
| [`kits/jupyter`](kits/jupyter) | JupyterLab with RTC + `jupyter-mcp-server` over stdio | 8888 | automatically |
| [`kits/desktop`](kits/desktop) | TigerVNC (Xvnc) + fluxbox + noVNC, resizes to the browser | 6080 | automatically |
| [`kits/burp`](kits/burp) | Burp Suite Pro + a Burp MCP server ([`burp-mcp-bridge`](https://github.com/fwaeytens/burp-mcp-bridge) by default) | 8080 | on demand |

Kits are composed at **create** time — `sbx kit add` on a running sandbox silently skips
`ports:` and `volumes:`, so a kit added later has nothing published.

## Use the wrapper

`bin/sbx-kits` composes the `sbx run` invocation and owns the parts no kit can: the shared
token, and fixed host ports.

```console
git clone https://github.com/abbbe/sbx-kits ~/.sbx/sbx-kits
~/.sbx/sbx-kits/bin/sbx-kits up            # creates a sandbox named after $PWD
~/.sbx/sbx-kits/bin/sbx-kits status        # sandbox state + per-service health
~/.sbx/sbx-kits/bin/sbx-kits urls          # URLs and token again
~/.sbx/sbx-kits/bin/sbx-kits shell         # a shell inside it
~/.sbx/sbx-kits/bin/sbx-kits svcs          # restart services that are down (see Lifecycle)
```

`up` prints the noVNC and JupyterLab URLs with the token filled in. Defaults live in
`~/.config/sbx-kits/config` (plain `KEY=value`), so `KITS=jupyter,desktop` or `MEMORY=12g`
there beats retyping flags. `--dry-run` prints the `sbx run` it would execute.

JupyterLab only: `sbx-kits up notebook --kits jupyter`.

The wrapper exists because the raw invocation is a dozen arguments, three of which must be
byte-identical to two others — an additional workspace mounts at its identical host path and
a kit cannot read the mount table, so each staged path has to be passed twice. It also always
passes `--detached`, without which the sandbox stops 30 seconds after the last session
disconnects, and it shifts off a busy host port rather than letting `sbx run` fail the whole
create with a 409.

## Everything, including Burp

Burp Pro and the Burp MCP server are staged on the host and mounted in — PortSwigger's download
needs your account, so nothing here can fetch Burp for you. Download the **platform installer**
matching your machine's architecture (`Linux (ARM)` on Apple Silicon, `Linux (x64)` on Intel)
from <https://portswigger.net/burp/releases/>, then:

```console
./kits/burp/stage-burp.sh --installer ~/Downloads/burpsuite_linux_arm64_v2026_8.sh
```

**Use the installer, not the standalone JAR.** The JAR's `chromium.properties` declares a
browser build for every platform including `linuxarm64`, but the JAR only *contains*
`chromium-{linux64,macosx64,win64}-*.zip`. Its `StandaloneJarChromiumBinaryInstaller` resolves
that archive as a classpath resource inside the JAR — not a download — so on arm64 Burp's
browser fails with no network traffic and nothing in the log. The platform installer takes the
other code path and ships the arm64 Chromium (verified: `ELF 64-bit ARM aarch64`, 151.0.7922.137),
plus PortSwigger's own JRE, which also silences the "your JRE appears to be … from Ubuntu"
warning. `--jar` still works as a fallback and warns about the browser.

The install runs unattended on first `burp-start.sh`, into `state/burp-install` — about 950 MB,
paid once, and it survives `sbx rm` with the rest of the state mount.

Then create the sandbox and do the one interactive step:

```console
./bin/sbx-kits up burpbox
sbx exec -it burpbox /home/agent/bin/burp-start.sh   # first run: EULA, then licence
```

Burp's first run is a console conversation, not a GUI wizard: it prints the EULA and blocks on
stdin, so it needs a terminal — that is why the command above uses `sbx exec -it`.
`dist/license.key` is at the same path inside the sandbox, so you can `cat` it there and paste. After that the activation lives in `state/java` on the host
and survives `sbx rm`.

## The desktop follows your browser window

Open the noVNC URL and the desktop sizes itself to the browser window, at 1:1 pixels — no
scaling, no letterboxing, no scrollbars. Resize the window and it follows.

That comes from two halves that both have to be right. The URL carries `?resize=remote`, which
is the noVNC setting that makes the client ask for a size rather than scale what it is given;
`sbx-kits urls` and `desktopctl url` both print it that way. The other half is the server:
`kits/desktop` runs TigerVNC's **Xvnc**, which is the X server and the VNC server in one
process, started with `-AcceptSetDesktopSize=1`.

It used to run Xvfb with x11vnc in front, and that pairing *cannot* do this. Xvfb welds its
framebuffer maximum on at startup — `xrandr` on the old stack reported `maximum 1920 x 1080`
against `maximum 32768 x 32768` on Xvnc — and x11vnc has no SetDesktopSize hook at all, so a
viewer asking for a different size was simply refused. All you could do was scale in the
browser and squint.

`$VNC_GEOMETRY` (default 1920x1080) is now only the size the desktop *starts* at, for whatever
happens before a viewer connects. When nothing is attached — a GUI the agent started headlessly,
a screenshot that has to come out at a known size — set it by hand:

```console
sbx exec burpbox /home/agent/bin/desktopctl resize 2560x1440
sbx exec burpbox /home/agent/bin/desktopctl status     # prints the current size
```

A viewer that connects later will override that, which is the right precedence: the viewer wins
when there is a viewer.

**A native client works too**, and gets the same dynamic resize, because Xvnc speaks RFB
directly. 5900 is not published, and that is deliberate — the RFB protocol truncates the
password to eight characters, so an exposed 5900 is a remote desktop behind eight characters.
`sbx-kits` has no flag for it on purpose. To do it anyway, take the command the wrapper would
have run and add the mapping yourself, loopback-only:

```console
./bin/sbx-kits up burpbox --dry-run      # prints the full sbx run line
<that line> -p 127.0.0.1:5900:5900       # then point a VNC viewer at localhost:5900
```

macOS's own Screen Sharing.app will connect but will not resize — it does not send
SetDesktopSize. A TigerVNC or RealVNC viewer does.

## One token

There is a single secret per sandbox at `/home/agent/.sbx-token`. Whichever kit's install step
runs first creates it and the rest reuse it, so any subset of the kits composes.

`sbx-kits up` generates it on the host, keeps it under `~/.local/state/sbx-kits/<name>.token`,
and pins it with `--kit-arg token=`. That matters for two reasons: `sbx run` surfaces no install
or startup output, so a sandbox has nowhere to announce a token it generated itself; and
`/home/agent/.sbx-token` is container overlay, so an `sbx kit add` container swap would
otherwise regenerate it and silently change your VNC password mid-session.

JupyterLab uses it as its access token and the desktop as its VNC password. Note the RFB
protocol truncates VNC passwords to **eight characters**, so the desktop is only ever protected
by the first eight — which is why 6080 belongs on `127.0.0.1` and nowhere else. One token also
means one leak exposes both services.

## Running a fork of the Jupyter MCP server

`kits/jupyter` installs `jupyter-mcp-server` from PyPI. The kit arg `jupyter_mcp_pkg` is whatever
`uv pip install` is handed, so a fork — or a pinned release — is one flag away:

```console
sbx-kits up --jupyter-mcp-pkg git+https://github.com/abbbe/jupyter-mcp-server@ca5973738b6ee5a0bfd7357697297dc78a782318
sbx-kits up --jupyter-mcp-pkg jupyter-mcp-server==2.1.12    # or just pin PyPI
```

A fork you are living on is not a per-invocation decision, so
`JUPYTER_MCP_PKG=git+https://…@<sha>` in `~/.config/sbx-kits/config` is usually the better home for it.
The wrapper flag exists because `sbx-kits` rejects arguments it does not know; underneath it
becomes `--kit-arg sbx-jupyter.jupyter_mcp_pkg=…`, namespaced because only that kit declares it.

Pin a **commit SHA**, not a branch: `@main` reinstalls whatever that branch points at on the day
you rebuild, which is not a pin. Use `git+https` and not the SSH remote — the container holds no
key, and a public fork does not need one. `uv` shells out to a real git, which the base agent
image already provides, so nothing else has to be installed.

Neither spelling reaches egress, though. `permissions.network.allow` is static and read at create
time, so `github.com:443` is listed unconditionally even though the default value never goes
there; a fork hosted anywhere else needs that file edited as well.

## Running a fork of the Burp MCP server

The Burp MCP server is two halves: an extension jar that publishes a JSON-RPC API on
127.0.0.1:8081 inside Burp, and a Node process that speaks MCP over stdio and calls it. They
arrive by different routes, and that is the one thing to keep straight.

The **node half is installed in the sandbox at create**, not staged — so npm resolves its ~90
transitive packages under the sandbox's own egress policy, where a dependency reaching somewhere
unexpected is a denied connection in `sbx policy log` rather than silent traffic from your laptop.
Nothing builds a `node_modules` tree on the host for a platform it is not running on, and
`stage-burp.sh` no longer needs `node` or `npm` at all.

The **extension jar is still staged**, because Burp loads extensions from a file path and nothing
in the sandbox builds Java.

So a fork is two coordinates that have to agree:

```console
./kits/burp/stage-burp.sh --installer … --burp-mcp-src you/burp-mcp-bridge@v2.8.0
./bin/sbx-kits up        --burp-mcp-src you/burp-mcp-bridge@v2.8.0
```

`stage-burp.sh` records what it staged, the kit records what it installed, and `burp-mcp.sh`
warns on stderr when the two disagree — the halves are versioned together and nothing else makes
them match. A ref with no release behind it yields no jar, so build it yourself and hand it over:

```console
mvn -f extension/pom.xml package
./kits/burp/stage-burp.sh --installer … --burp-mcp-src you/burp-mcp-bridge@my-branch \
    --burp-mcp-jar ~/github/burp-mcp-bridge/extension/target/burp-mcp-bridge-2.8.0.jar
```

### When upstream publishes to npm

`--burp-mcp-pkg` takes an npm install spec and wins over `--burp-mcp-src`, which is the better
setting the day it exists — a registry coordinate, exactly like the jupyter kit's
`--jupyter-mcp-pkg`, and `github.com:443` plus `codeload.github.com:443` can then leave this kit's
allowlist. It is empty today only because `burp-mcp-bridge` is not on npm. Note that npm has no
equivalent of pip's `#subdirectory=`, and upstream keeps `package.json` in `bridge/` rather than at
the repo root, so a `git+https` URL cannot work here the way it does for the Jupyter kit — a fork
is selected by version or by a scoped package name, not by commit SHA.

### Swapping in a different MCP server

A different implementation, rather than a fork of this one, is a bigger job, but the kit no longer
fights you on three of the pieces:

- **The extension is a drop-in.** `files/home/etc/burp/extensions.d/*.json` is merged into Burp's
  extension list when the user config is first seeded, `@BURP_DIST@` expanded as in the seed.
  Add a `.json`, get an extension; the seed itself names none.
- **Nothing blocks on the MCP port.** `burp-start.sh` waits only for the proxy. The MCP API gets a
  bounded advisory probe — `BURP_MCP_WAIT` seconds, default 30, and `BURP_MCP_WAIT=0` for a server
  that binds no TCP port at all.
- **`BURP_API_PORT` now sets the port on both sides**, exported to Burp as `BURP_MCP_SERVER_PORT`
  for the extension to read. It used to configure only the clients while the extension bound its
  own default, so any value but 8081 broke the pairing silently.

What remains specific to upstream: the `bridge/` source layout, and `MCP_TRANSPORT_MODE` /
`BURP_MCP_SERVER_PORT` as the env-var spellings that select stdio and the API port. See
`kits/burp/spec.yaml` and `files/home/bin/burp-mcp.sh`.

## Ports: use `-p`, don't rely on the automatic ones

Each kit declares its port, and sbx auto-publishes those on ephemeral host ports. Two measured
reasons not to depend on them:

They are **reallocated when the sandbox restarts** — one sandbox went from 49166/67/68 at
create to 49169/70/71 after a stop/start, with the old numbers dead. Any bookmark goes stale.

And they are published dual-stack (`protocol:` accepts only `tcp` or `udp` in a kit, never
`tcp4`), so a service that binds IPv4-only inside the sandbox is unreachable over the `::1`
half — and macOS tries `::1` first, so `localhost:<port>` fails while `127.0.0.1:<port>`
works. Measured on this kit: Burp's own listener binds dual-stack and is fine either way,
but websockify had to be given `[::]` explicitly to stop being IPv4-only.

An explicit `-p 6080:6080` defaults to `tcp4`, which is stable and matches any listener.

## Egress is default-deny

Burp's own traffic is subject to the sandbox network policy, so the sandbox doubles as a scope
guard. Per engagement, on the host:

```console
sbx policy allow network --sandbox burpbox "target.example.com:443"
sbx policy check network target.example.com --sandbox burpbox   # states the reason
```

To find out what a kit reaches for, probe it under `deny-all` on a throwaway daemon:

```console
APP=sbx-kits-probe
sbx --app-name $APP policy init deny-all
sbx --app-name $APP create --name probe --kit "$PWD/kits/burp" claude /tmp/probe || true
sbx --app-name $APP policy log probe
sbx --app-name $APP reset --force
```

## Routing traffic through Burp

There is deliberately **no** global `HTTP_PROXY`: it would apply to every process including
Claude Code, sending the session's own Anthropic API traffic through Burp and leaving its
credentials in the proxy history. Opt in per command instead:

```console
via-burp curl -sS https://target.example.com/
```

In JupyterLab, pick the **Python 3 (via Burp)** kernel. Burp's CA is installed system-wide by
`burp-start.sh`; that is safe precisely *because* there is no global proxy — trusting a CA
redirects nothing by itself.

## Lifecycle

```console
sbx-kits down burpbox      # stop
sbx-kits wake burpbox      # start again without spawning the Claude TUI
sbx-kits svcs burpbox      # start whichever services are not running
sbx-kits destroy burpbox   # remove it (host-staged Burp state is untouched)
```

Burp does not come back by itself after a restart — run `burp-start.sh` again, or
`sbx-kits burp burpbox`.

**The desktop and JupyterLab do not come back by themselves either, as of sbx 0.45.1.** They
used to, on 0.43.0: a kit declares each one as a `setup.startup` background command, and a
stop/start cycle re-dispatched it. It no longer does — measured on an idle sandbox, both
`sbx exec <name> true` and `sbx run -d --name <name>` bring the container back with a fresh
PID 1 and no startup commands, so the sandbox comes up carrying `tini`, `sleep infinity` and
`dockerd` and nothing else. The symptom is a sandbox that `sbx ls` calls `running` with every
service down, and it also happens without a stop you asked for: upgrading the sbx cask
restarts sandboxd, which takes every running container down with it.

`wake` therefore starts the services as well, and `svcs` does that half on its own — for a
sandbox that came back some other way, or after the daemon restarted underneath you. It is
idempotent: it starts only what is not already there, so running it when unsure costs nothing.
A second supervisor would be worse than none (both service scripts are their own restart
loops, and the one that loses the race for the port respawns forever), so it refuses to stack
one, and it leaves a port alone when something that is not the supervisor is holding it.

Unlike the startup dispatcher, which ran these scripts with their output going nowhere, `svcs`
gives each one a log: `~/.local/state/sbx-kits/{jupyter,desktop}-svc.log` inside the sandbox.

## Memory

A mixin cannot raise the sandbox's memory limit, so it has to come from the command line;
`sbx-kits up` passes `-m 8g` by default (`--memory`, or `MEMORY=` in the config file). Burp runs
with `-XX:MaxRAMPercentage=50`, which reads the cgroup limit, so it tracks whatever the sandbox
was given without the kit knowing the number.
