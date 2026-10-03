"""A release tarball records root (0/0) as the owner of every entry.
Usage: python3 scripts/tarball_owner_check.py TARBALL

A tar that unpacks as root keeps the owner the tarball records unless told
otherwise. A tarball packed on a CI runner records the runner's uid (1001),
which on a server is often a real account, and that account could then
rewrite the bin/at_mcp that systemd and root run. Recorded as root, the
tarball is safe however it is unpacked.
"""

import sys
import tarfile

with tarfile.open(sys.argv[1]) as tarball:
    wrong = [(m.name, m.uid, m.gid) for m in tarball if m.uid != 0 or m.gid != 0]
if wrong:
    sys.exit("%s records owners other than root: %d entries, e.g. %s" % (sys.argv[1], len(wrong), wrong[:3]))
print("%s: every entry is owned by 0/0" % sys.argv[1])
