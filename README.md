# sbx-kits: JupyterLab, a desktop, a browser, and Burp Suite Pro

Four mixin kits for [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) (`sbx`),
composed onto the stock `claude` agent. Each one works alone; together they give a sandbox
where Claude drives Burp and a real browser over MCP, you watch and click both GUIs from
your own browser, and JupyterLab is there for scripting.

| kit | what it adds | port | starts |
|---|---|---|---|
| [`kits/jupyter`](kits/jupyter) | JupyterLab with RTC + `jupyter-mcp-server` over stdio | 8888 | automatically |
| [`kits/desktop`](kits/desktop) | TigerVNC (Xvnc) + fluxbox + noVNC, resizes to the browser | 6080 | automatically |
| [`kits/browser`](kits/browser) | Chromium on the desktop + [`@playwright/mcp`](https://github.com/microsoft/playwright-mcp) over stdio | — | on demand |
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

## A browser on the desktop, and the same one over MCP

`kits/browser` puts **Web Browser** in the desktop's Applications menu and registers
`@playwright/mcp` as a stdio MCP server. Both drive the *same Chromium binary*, so a page
that renders for you renders for Claude.

There is no `chromium` package on the system, and that is not an oversight. Ubuntu's
`chromium` and `firefox` debs have been transitional **snap stubs** since 22.04 — apt installs
them happily and the launcher then execs `snapd`, which no container has. Google publishes no
arm64 Linux Chrome deb at all, so on an Apple Silicon host that route is closed too. What this
kit runs instead is the **Chrome for Testing** build Playwright downloads: a real Chromium,
built for `linux-arm64` and `linux-x64` both. Playwright 1.64 carries a first-class
`ubuntu26.04-arm64` target, so this is a supported combination rather than a lucky one.

**The agent's browser is headed by default**, on `$DISPLAY`, so whoever is watching noVNC sees
the page Claude is on. `playwright-mcp.sh` waits up to 30s for the X server before deciding —
the MCP server is spawned at session start and the desktop is a background command racing it,
and choosing headless one second too early is invisible: no error, just a human staring at an
empty desktop while the agent reports pages loading. With no desktop kit composed in it goes
straight to headless and everything else is the same.

**Your browser and the agent's are different processes on different profiles**, and they have
to be: Chromium takes an exclusive lock on a user-data-dir, and a second launch against the
same one does not open a window, it hands its command line to the running instance and exits.
Sharing a profile would mean whichever started second silently became a tab in the first.
So logins do not carry across — that is the cost of both of you browsing at once.

```console
browser                                   # your Chromium, on the desktop
browser https://target.example.com/       # …at a URL
browser --via-burp https://target/        # …through Burp, trusting its CA
browser --profile ~/p2                    # a genuinely second window
```

`--via-burp` does something the burp kit cannot do for you: **Chromium does not read
`/etc/ssl/certs`.** `burp-start.sh` installs Burp's CA into the system bundle, which is what
`curl` and `python` then trust, and Chromium ignores all of it because NSS keeps its own
database in `~/.pki/nssdb`. So the same CA has to be added a second time, in the other format,
or every proxied page is an interstitial. For the agent's browser, put
`--proxy-server=http://127.0.0.1:8080` in `$PLAYWRIGHT_MCP_ARGS` and reconnect with `/mcp`.

### Chromium keeps its own sandbox here

Every Chromium-in-Docker recipe passes `--no-sandbox`. This one does not, because it does not
need to: measured on the running browser, every `--type=renderer` has `Seccomp: 2` in
`/proc/<pid>/status` and sits in a user namespace distinct from the browser process's, and
`unshare --user --map-root-user` succeeds. The renderer's privilege separation is the thing
standing between a hostile page and the rest of the sandbox, and there is no reason to trade it
away. (Playwright *does* disable it for the `chrome-for-testing` channel, so the MCP browser
runs without it regardless — that is Playwright's portability default for hosts where the
namespace is unavailable, not a statement about this one.)

Two flags that are not optional: `--disable-dev-shm-usage`, because `/dev/shm` is 64M in a
container and busy pages otherwise die as "Aw, Snap" with nothing in the log naming the cause;
and the `--disable-*-networking` family, because under default-deny egress Chromium's component
updater and variations service retry blocked endpoints forever and bury anything real in
`browser.log`.

### Pinning it, or running a fork

One coordinate fixes both halves — the package pins an exact `playwright`, and the Chromium
downloaded at create is the revision that `playwright` names:

```console
sbx-kits up --playwright-mcp-pkg '@playwright/mcp@0.0.81'
sbx-kits up --playwright-mcp-pkg 'github:you/playwright-mcp#<sha>'
```

`PLAYWRIGHT_MCP_PKG=` in `~/.config/sbx-kits/config` is the better home for a fork you are
living on. As with the other kits, `permissions.network.allow` is static and read at create
time, so a source outside npm and GitHub needs `kits/browser/spec.yaml` edited as well.

The kit costs about **680 MB** installed — `playwright install chromium` fetches the headless
shell and ffmpeg alongside the browser. `--kit-arg sbx-browser.browsers='chromium firefox
webkit'` gets the other two engines for Playwright scripts, at roughly 500 MB more; note
Playwright's firefox and webkit are *patched* builds that nothing but Playwright can drive, and
neither is wired into the menu entry.

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

In JupyterLab, pick the **Python 3 (via Burp)** kernel. In the browser, `browser --via-burp`
— which also has to add Burp's CA to Chromium's NSS database, because Chromium does not read
the system bundle at all. Burp's CA is installed system-wide by `burp-start.sh`; that is safe
precisely *because* there is no global proxy — trusting a CA redirects nothing by itself.

## Lifecycle

```console
sbx-kits down burpbox      # stop
sbx-kits wake burpbox      # start again without spawning the Claude TUI
sbx-kits destroy burpbox   # remove it (host-staged Burp state is untouched)
```

Burp does not come back by itself after a restart — run `burp-start.sh` again. Neither does the
browser: it is started by you from the menu, and by Claude on its first `browser_*` tool call.
The desktop and JupyterLab do come back on their own.

## Memory

A mixin cannot raise the sandbox's memory limit, so it has to come from the command line;
`sbx-kits up` passes `-m 8g` by default (`--memory`, or `MEMORY=` in the config file). Burp runs
with `-XX:MaxRAMPercentage=50`, which reads the cgroup limit, so it tracks whatever the sandbox
was given without the kit knowing the number.
