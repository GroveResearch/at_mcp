"""A built release, run as docs/operations.md says, answers every operator command.
Usage: python3 scripts/foreground_boot_check.py /absolute/release

Under a scratch root and HOME it lays the release out beside nothing else
(releases/, current, one environment file, a private state folder, both under
a path with a space in it), starts it the way the example launchd plist does
(a shell exports the environment file and becomes `bin/at_mcp start`, in the
foreground). First, with a value containing a space written without its
quotes, the start must stop before AtMcp runs, rather than run with that
setting unset (an unset AT_MCP_ACCOUNTS_FILE is another installation's default
file). Then, with the file written as Operations says, and with only
AT_MCP_ENV_FILE naming that file:

- `at_mcp-accounts add` logs two accounts in to a loopback PDS, `reload` starts
  them, `status` shows both ready, `disconnect` and `reconnect` answer;
- `at_mcp-accounts connection` issues a grant the MCP endpoint accepts, and the
  endpoint refuses a request without one;
- `bin/at_mcp pid` and `remote` reach the node;
- the node's cookie is the environment file's RELEASE_COOKIE, not the
  releases/COOKIE every copy of the release carries;
- no port mapper (epmd) is reachable -- ERL_EPMD_PORT names a port where nothing
  listens -- and the node listens on 127.0.0.1 alone, at its distribution port
  and its MCP port and nowhere else;
- SIGTERM, what launchd and systemd send to stop it, ends the service with
  status 0, so the plist's KeepAlive and the unit's Restart=on-failure leave
  it stopped.

CI runs it on Linux on every pull request, and on macOS before a release is
published.
"""

import pathlib
import re
import socket
import subprocess
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "support"))
from release_run import FakePDS, Foreground, Install, poll  # noqa: E402

release = pathlib.Path(sys.argv[1]).resolve()
pds = FakePDS()
manager = Foreground(tempfile.mkdtemp(prefix="at_mcp-boot-"), release / "examples")
at_mcp = Install(manager, pds)

# Every TCP socket the node listens on, as `listening ADDRESS PORT` lines.
LISTENING = """
for port <- Port.list(),
    Port.info(port, :name) == {:name, ~c"tcp_inet"},
    {:ok, flags} <- [:prim_inet.getstatus(port)],
    :listen in flags,
    {:ok, {ip, number}} when is_tuple(ip) <- [:inet.sockname(port)],
    do: IO.puts("listening #{:inet.ntoa(ip)} #{number}")
"""

try:
    at_mcp.unpack(release, "at_mcp-check")
    at_mcp.repoint("at_mcp-check")

    # A bad environment file stops the start.
    at_mcp.lay_out(quote=False)
    manager.start()
    refused = manager.exited()
    assert refused != 0, ("started with an unquoted spaced value", refused, manager.logs()[-2000:])
    assert not at_mcp.ready()

    at_mcp.lay_out()
    manager.start()
    poll(at_mcp.ready)

    for name in ("alice", "bob"):
        at_mcp.add(name)
    assert at_mcp.accounts(["reload"])["ok"]
    rows = at_mcp.status()
    assert sorted(rows) == ["alice", "bob"] and all(r["ready"] for r in rows.values()), rows

    assert at_mcp.accounts(["disconnect", "bob"])["ok"]
    assert at_mcp.status()["bob"]["disconnected"], at_mcp.status()
    assert at_mcp.accounts(["reconnect", "bob"])["ok"]
    assert at_mcp.status()["bob"]["ready"], at_mcp.status()

    grant = at_mcp.grant("alice")
    assert at_mcp.mcp(grant) == 200, at_mcp.mcp(grant)
    assert at_mcp.mcp() == 401, at_mcp.mcp()

    # The cookie: the file's, and not the one inside the release, which anyone
    # who downloads the release has. Compared here and never printed.
    cookie = at_mcp.command(["bin/at_mcp", "rpc", "IO.puts(Node.get_cookie())"]).stdout.strip().splitlines()[-1]
    shipped = (pathlib.Path(at_mcp.current) / "releases" / "COOKIE").read_text().strip()
    assert cookie == at_mcp.cookie, "the node's cookie is not the environment file's"
    assert cookie != shipped, "the node runs with the release's own cookie"

    listening = at_mcp.command(["bin/at_mcp", "rpc", LISTENING])
    sockets = sorted(re.findall(r"^listening (\S+) (\d+)$", listening.stdout, re.M))
    expected = sorted([("127.0.0.1", str(at_mcp.dist_port)), ("127.0.0.1", str(at_mcp.mcp_port))])
    assert sockets == expected, (sockets, expected, listening.stdout)
    with socket.socket() as probe:
        assert probe.connect_ex(("127.0.0.1", at_mcp.epmd_port)) != 0, "a port mapper is listening"

    pid = at_mcp.command(["bin/at_mcp", "pid"]).stdout.strip()
    assert pid == str(manager.pid()), (pid, manager.pid())

    # `remote` reaches it too. End of input would halt the service it is
    # attached to, so the session is ended by stopping its own process.
    remote = subprocess.Popen(
        ["env", "AT_MCP_ENV_FILE=" + str(at_mcp.env_path), at_mcp.current + "/bin/at_mcp", "remote"],
        env=manager.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    try:
        remote.stdin.write('IO.puts("remote " <> System.pid())\n')
        remote.stdin.flush()
        seen = ""
        while not re.search(r"remote \d+\n", seen):
            line = remote.stdout.readline()
            assert line, seen
            seen += line
        assert "remote %s\n" % pid in seen, (pid, seen)
    finally:
        remote.terminate()
        remote.wait(timeout=30)

    status = manager.stop()
    assert status == 0, (status, manager.logs()[-4000:])

    print("ran %s as Operations says; a bad environment file stopped the start (status %d); "
          "two accounts ready; every operator command answered" % (release, refused))
except BaseException:
    sys.stderr.write(manager.logs()[-6000:])
    raise
finally:
    manager.cleanup()
    pds.close()
