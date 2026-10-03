"""Upgrade from release N to N+1 and roll back, as docs/operations.md says.
Usage: python3 scripts/upgrade_rollback_check.py [--systemd | --launchd] N N+1

N and N+1 are built releases (directories). Both are unpacked side by side
under one prefix; `current` points at N and the service runs it. Then:

- Under N, two accounts are added and ready, a grant is issued and the MCP
  endpoint accepts it, one account is disconnected, the other makes one write
  (counted in write-quota.json) and has one collected event waiting in the
  delivery queue (inbound.term; nothing is configured to deliver it).
- Upgrade: `current` is repointed at N+1 and the service restarted. N+1
  starts on what N left: the ready account is ready, the disconnected one is
  still disconnected, N's grant is still accepted, one write is counted and
  one event is pending. Under N+1 a second grant is issued, a second write
  made, a second event accepted and the account reconnected.
- Rollback: the service is stopped, `current` repointed at N and the service
  started. N starts on what N+1 left: both accounts ready, both grants
  accepted, two writes counted and two events pending.

So every file AtMcp stores -- the accounts file, the grants file, the write
quota and the delivery queue -- is written by each release and read by the
other. AtMcp has no stored-data format change between releases, so nothing is
backed up and nothing is restored. When a release changes the format of one of
these files, this check fails, and that release must take its own copy at
start and Operations must say how to put it back.

`--systemd` installs the example unit (rel/examples/at_mcp.service) for real, as
root, and `--launchd` the example plist, as the user; both change the machine
and run only on a CI runner. Under the unit it also checks that the service
cannot read another user's command line, which is where the release puts the
Erlang cookie (the unit's ProtectProc=invisible). Without either the service
runs as the example launchd plist runs it, as a child of this script under a
scratch root and HOME.
"""

import argparse
import pathlib
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "support"))
from release_run import FakePDS, Foreground, Install, Launchd, Systemd, poll  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--systemd", action="store_true")
parser.add_argument("--launchd", action="store_true")
parser.add_argument("old")
parser.add_argument("new")
args = parser.parse_args()

old = pathlib.Path(args.old).resolve()
new = pathlib.Path(args.new).resolve()

# The unit is installed once, from N+1, the release this repository builds.
examples = new / "examples"
if args.systemd:
    manager = Systemd(examples)
elif args.launchd:
    manager = Launchd(examples)
else:
    manager = Foreground(tempfile.mkdtemp(prefix="at_mcp-upgrade-"), examples)
pds = FakePDS()
at_mcp = Install(manager, pds)


def states():
    return {name: ("disconnected" if row.get("disconnected") else "ready" if row.get("ready") else "down")
            for name, row in at_mcp.status().items()}


try:
    at_mcp.unpack(old, "at_mcp-N")
    at_mcp.unpack(new, "at_mcp-N1")
    at_mcp.repoint("at_mcp-N")
    at_mcp.lay_out()
    if args.systemd or args.launchd:
        manager.install_unit()
    manager.start()
    poll(at_mcp.ready)
    if args.systemd:
        manager.check_hides_other_processes()

    # Under N.
    for name in ("alice", "bob"):
        at_mcp.add(name)
    assert at_mcp.accounts(["reload"])["ok"]
    poll(lambda: states() == {"alice": "ready", "bob": "ready"})
    first = at_mcp.grant("alice")
    assert at_mcp.mcp(first) == 200
    assert at_mcp.accounts(["disconnect", "bob"])["ok"]
    assert states() == {"alice": "ready", "bob": "disconnected"}, states()
    at_mcp.post("alice")
    at_mcp.accept("alice", 1)
    at_mcp.checkpoint("alice", 1000000)
    first_events = at_mcp.queued_uris()
    assert (at_mcp.writes_used("alice"), at_mcp.pending()) == (1, 1)

    # Upgrade: unpack beside, repoint, restart.
    manager.stop()
    at_mcp.repoint("at_mcp-N1")
    at_mcp.lay_out()
    if args.systemd or args.launchd:
        manager.install_unit()
    manager.start()
    poll(at_mcp.ready)
    poll(lambda: states() == {"alice": "ready", "bob": "disconnected"})
    assert at_mcp.mcp(first) == 200, "N+1 refused the grant N issued"
    assert at_mcp.checkpoints("alice") == "[1000000,1000000]", "N+1 lost N's collection checkpoints"
    assert at_mcp.queued_uris() == first_events, "N+1 changed N's queued event contents"
    assert (at_mcp.writes_used("alice"), at_mcp.pending()) == (1, 1), "N+1 lost N's write or event"
    at_mcp.post("alice")
    at_mcp.accept("alice", 2)
    at_mcp.checkpoint("alice", 2000000)
    both_events = at_mcp.queued_uris()
    assert (at_mcp.writes_used("alice"), at_mcp.pending()) == (2, 2)
    second = at_mcp.grant("alice")
    assert at_mcp.mcp(second) == 200
    assert at_mcp.accounts(["reconnect", "bob"])["ok"]
    assert states() == {"alice": "ready", "bob": "ready"}, states()

    # Roll back: stop, repoint, start. Nothing is restored.
    manager.stop()
    at_mcp.repoint("at_mcp-N")
    at_mcp.lay_out()
    if args.systemd or args.launchd:
        manager.install_unit()
    manager.start()
    poll(at_mcp.ready)
    poll(lambda: states() == {"alice": "ready", "bob": "ready"})
    assert at_mcp.mcp(first) == 200 and at_mcp.mcp(second) == 200, "N refused a grant"
    assert at_mcp.checkpoints("alice") == "[2000000,2000000]", "N lost N+1's collection checkpoints"
    assert at_mcp.queued_uris() == both_events, "N lost or changed N+1's queued events"
    assert (at_mcp.writes_used("alice"), at_mcp.pending()) == (2, 2), "N lost N+1's writes or events"
    assert at_mcp.mcp() == 401

    status = manager.stop()
    assert status == 0, status
    print("upgraded %s -> %s and rolled back; accounts, disconnection, grants, write quota, collection checkpoints and pending "
          "delivery carried both ways; "
          "no stored-data format change, so nothing was backed up or restored" % (old.name, new.name))
except BaseException:
    sys.stderr.write(manager.logs()[-8000:])
    raise
finally:
    manager.cleanup()
    pds.close()
