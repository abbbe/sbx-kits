#!/usr/bin/env python3
"""Prune a harvested Burp preferences file down to what is safe to re-seed.

Called by stage-burp.sh --harvest.  Runs on the HOST, like the rest of staging,
and is deliberately not under files/ so it never ships into a sandbox.

WHAT SURVIVES is everything not listed in DROP below: crucially burp.eula (the
accepted licence-agreement version), license1 (the licence key itself) and the
opaque activation record PortSwigger hands back, which together are what stop
every new sandbox spending another activation.

WHAT IS DROPPED, and why each one:

  caCert            Burp's certificate authority -- PRIVATE KEY INCLUDED, as a
                    PKCS#12 blob.  Seeding it would put ONE CA in every sandbox,
                    so a certificate minted while proxying one engagement is
                    trusted by a sandbox looking at another.  Burp mints a fresh
                    CA on first run when this is absent, which is what we want:
                    per-sandbox, like everything else Burp writes.
  recentProject*    Filesystem paths to another sandbox's project files.  They
                    are that engagement's history, not configuration, and the
                    paths do not exist here anyway.
  availablebapps*   ~1.7MB of cached BApp Store catalogue in 8KB chunks.  Pure
                    cache; Burp refetches it.  Dropping it is the difference
                    between a 1.7MB seed and a ~15KB one.
  frame*, working*  Window geometry and last-used directories from whatever
                    screen the harvested sandbox was displayed on.

The file is Java's Preferences XML: a flat <map> of <entry key= value=/>, so a
line-oriented rewrite is the honest tool.  It is NOT parsed as general XML on
purpose -- the values are base64 blobs up to 8KB and round-tripping them through
a DOM buys nothing.
"""
import re
import sys

DROP = re.compile(
    r"^("
    r"caCert"
    r"|burp\.suite\.recentProject\w*"
    r"|burp\.extensions\.availablebapps\w*"
    r"|burp\.suite\.frame\w*"
    # workingdirectory-4, not workingdirectory4: the suffix is a dash and a
    # digit, which \w does not cover.  Missed that once and the host's staging
    # path rode into the seed.
    r"|workingdirectory[\w-]*"
    r")$"
)

REQUIRED = "burp.eula"


def main(src, dst):
    raw = open(src, encoding="utf-8").read()
    kept, dropped = [], []

    def keep(m):
        key = m.group(1)
        if DROP.match(key):
            dropped.append(key)
            return ""
        kept.append(key)
        return m.group(0)

    out = re.sub(r'[ \t]*<entry key="([^"]*)" value="[^"]*"/>\n?', keep, raw)

    # REFUSE RATHER THAN WRITE A USELESS SEED.  A prefs.xml without burp.eula
    # seeds nothing useful, and the failure would only surface much later as a
    # sandbox that unexpectedly wants the licence agreement on its terminal.
    if REQUIRED not in kept:
        sys.exit("prune-prefs: no %s in %s -- refusing to write a seed" % (REQUIRED, src))

    with open(dst, "w", encoding="utf-8") as fh:
        fh.write(out)

    print("    kept %d entries, dropped %d (CA, recent projects, BApp cache, geometry)"
          % (len(kept), len(dropped)))
    for k in (REQUIRED, "license1"):
        print("      %-10s %s" % (k, "present" if k in kept else "MISSING"))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: prune-prefs.py SRC DST")
    main(sys.argv[1], sys.argv[2])
