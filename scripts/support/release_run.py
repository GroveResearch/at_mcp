"""A AtMcp release laid out and run the way docs/operations.md says.

`Install` is one installation: releases unpacked side by side under a prefix,
`current` pointing at one of them, one environment file, a private state
folder holding the accounts file and the stores, and a service manager
running `current/bin/at_mcp start` with that file loaded. Each manager takes its
unit from `examples`, the examples/ folder of the release the unit was
installed from (it stays installed across upgrades and rollbacks):

- `Foreground`, what the example launchd plist runs (a shell exports the
  environment file and becomes `bin/at_mcp start`), as a child process of this
  script, stopped with SIGTERM as launchd stops it. Anyone can run it, under a
  scratch root and HOME. Its environment file and state folder are under
  `Application Support`, so their paths have a space, as on a Mac.
- `Systemd`, the example unit itself, installed as /etc/systemd/system/at_mcp.service
  and driven with systemctl, as root with a `at_mcp` user. It writes /opt, /etc
  and /var/lib.
- `Launchd`, the example plist itself, installed in ~/Library/LaunchAgents and
  driven with launchctl, with everything under ~/at_mcp as Operations lays it
  out.

The last two change the machine they run on, so they refuse to run anywhere
but a CI runner (CI=true), which is thrown away afterwards.

Operator commands run the way Operations says to run them: with
AT_MCP_ENV_FILE naming the environment file. Accounts log in to `FakePDS`, a
loopback PDS that answers session, profile and record requests.
"""

import http.server
from urllib.parse import parse_qs, urlsplit
import json
import os
import pathlib
import pwd
import re
import shutil
import signal
import socket
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def poll(fn, tries=150, pause=0.4):
    last = None
    for _ in range(tries):
        try:
            val = fn()
            if val:
                return val
        except Exception as error:  # noqa: BLE001 -- polled until it holds
            last = error
        time.sleep(pause)
    raise AssertionError("poll exhausted; last error: %r" % (last,))


class FakePDS:
    """A PDS on loopback that logs in any handle whose password is PASSWORD and
    accepts any record it is asked to create."""

    PASSWORD = "fixture-app-password"
    created = 0

    def __init__(self):
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
                if self.path == "/xrpc/com.atproto.server.createSession" and body.get("password") == FakePDS.PASSWORD:
                    name = body["identifier"]
                    self.answer(200, {"did": "did:plc:" + name, "handle": name,
                                      "accessJwt": "fixture-access", "refreshJwt": "fixture-refresh"})
                elif self.path == "/xrpc/com.atproto.server.createSession":
                    self.answer(401, {"error": "AuthenticationRequired"})
                elif self.path == "/xrpc/com.atproto.repo.createRecord":
                    FakePDS.created += 1
                    self.answer(200, {"uri": "at://%s/%s/%d" % (body.get("repo"), body.get("collection"), FakePDS.created),
                                      "cid": "bafyreie5737gdxlw5i64vzichcalba3z2v5n6icifvx5xytvske7mr3hpm"})
                else:
                    self.answer(404, {"error": "NotFound"})

            def do_GET(self):
                url = urlsplit(self.path)
                if url.path == "/xrpc/app.bsky.actor.getProfile":
                    did = parse_qs(url.query)["actor"][0]
                    self.answer(200, {"did": did, "handle": did.removeprefix("did:plc:"),
                                      "displayName": "Fixture account"})
                else:
                    self.do_POST()

            def answer(self, status, payload):
                data = json.dumps(payload).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = "http://127.0.0.1:%d" % self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()


def env_file(settings, quote=True):
    """NAME=value lines, as docs/operations.md says: a value with a space is double-quoted.

    sh (the launchd plist, rel/env.sh.eex) and systemd's EnvironmentFile= both
    read a double-quoted value holding no `$`, backslash or backtick the same.
    `quote=False` writes a spaced value bare, the mistake the plist must refuse.
    """
    lines = []
    for name, value in settings.items():
        assert not any(c in value for c in '$\\`"'), (name, value)
        lines.append('%s="%s"\n' % (name, value) if quote and " " in value else "%s=%s\n" % (name, value))
    return "".join(lines)


class Install:
    def __init__(self, manager, pds):
        self.manager = manager
        self.pds = pds
        self.dist_port = free_port()
        self.mcp_port = free_port()
        # Where a port mapper would be. Nothing listens there, so the release
        # sees a machine with none, and this machine's own are never touched.
        self.epmd_port = free_port()
        self.cookie = os.urandom(24).hex()

    @property
    def current(self):
        return str(self.manager.prefix / "current")

    @property
    def env_path(self):
        return self.manager.etc / "at_mcp.env"

    def settings(self):
        m = self.manager
        settings = {
            "AT_MCP_ACCOUNTS_FILE": str(m.state / "accounts.json"),
            "AT_MCP_STATE_DIR": str(m.state),
            "RELEASE_COOKIE": self.cookie,
            "AT_MCP_DIST_PORT": str(self.dist_port),
            "AT_MCP_PORT": str(self.mcp_port),
            "AT_MCP_NOTIFICATIONS": "0",
            "ERL_EPMD_PORT": str(self.epmd_port),
            # Its own node name, so it can run beside another AtMcp here.
            "RELEASE_NODE": "at_mcp_check_%d" % os.getpid(),
        }

        if self.legacy:
            settings = {("KITE_MCP_PORT" if key == "AT_MCP_PORT" else key.replace("AT_MCP_", "KITE_")): value
                        for key, value in settings.items()}
        return settings

    @property
    def legacy(self):
        # Explicit old-release comparison, never production fallback behavior.
        return not (pathlib.Path(self.current) / "bin" / "at_mcp").exists()

    def lay_out(self, quote=True):
        """The environment file and the state folder."""
        m = self.manager
        m.make_private_dir(m.etc)
        m.write_private(self.env_path, env_file(self.settings(), quote=quote))
        m.make_state_dir()

    def unpack(self, release, name):
        """Pack a release as CI does and unpack it with README's `tar` line."""
        target = self.manager.prefix / "releases" / name
        work = pathlib.Path(tempfile.mkdtemp(prefix="at_mcp-tarball-"))
        try:
            shutil.copytree(release, work / "at_mcp", symlinks=True)
            tarball = work / "at_mcp.tar.gz"
            subprocess.run(["tar"] + self.manager.pack_owner + ["-C", str(work), "-czf", str(tarball), "at_mcp"], check=True)
            self.manager.run(["mkdir", "-p", str(target)])
            self.manager.run(["tar", "--no-same-owner", "--strip-components=1", "-xzf", str(tarball), "-C", str(target)])
        finally:
            shutil.rmtree(work, ignore_errors=True)
        self.manager.check_owner(target)
        return target

    def repoint(self, name):
        self.manager.run(["ln", "-sfn", "releases/" + name, self.current])
        self.manager.release_command = "kite" if self.legacy else "at_mcp"

    def command(self, args, check=True, timeout=120, stdin=None):
        """A command of the current release, run from a shell as Operations says."""
        release = os.path.realpath(self.current)
        prefix = "KITE_ENV_FILE=" if self.legacy else "AT_MCP_ENV_FILE="
        if self.legacy:
            args = [arg.replace("bin/at_mcp", "bin/kite").replace("AtMcp.", "Kite.") for arg in args]
        argv = ["env", prefix + str(self.env_path), os.path.join(release, args[0])] + args[1:]
        p = self.manager.as_service_user(argv, timeout=timeout, stdin=stdin)
        if check and p.returncode:
            raise RuntimeError((args, p.returncode, p.stderr[-4000:], p.stdout[-2000:]))
        return p

    def accounts(self, args, stdin=None, check=True):
        p = self.command(["bin/at_mcp-accounts"] + args, stdin=stdin, check=check)
        return json.loads(p.stdout) if check else p

    def ready(self):
        out = self.command(["bin/at_mcp", "rpc", "AtMcp.CLI.service_status()"], check=False).stdout
        return '"ready":true' in out

    def add(self, name):
        self.accounts(["add", name, "--handle", name, "--service", self.pds.url, "--password-stdin"],
                      stdin=FakePDS.PASSWORD + "\n")

    def status(self):
        """{id: row} from `at_mcp-accounts status`."""
        return {row["id"]: row for row in self.accounts(["status"])["accounts"]}

    def grant(self, name):
        """A new grant for `name`, from `at_mcp-accounts connection`."""
        headers = self.accounts(["connection", name])["mcp"]["headers"]
        return next(h["value"] for h in headers if h["name"] == "authorization")

    def rpc(self, expression):
        """The last line `bin/at_mcp rpc` prints for an expression."""
        return self.command(["bin/at_mcp", "rpc", expression]).stdout.strip().splitlines()[-1]

    def post(self, name):
        """One write through the account's owner, so the write quota records it."""
        return self.rpc('{:ok, %%{uri: uri}} = AtMcp.Effects.post(AtMcp.Identity.effects_name("%s"), '
                        '"upgrade check"); IO.puts(uri)' % name)

    def writes_used(self, name):
        return int(self.rpc('IO.puts(AtMcp.WriteQuota.status("did:plc:%s").used)' % name))

    def accept(self, name, n):
        """One collected event for `name`, accepted into the delivery queue.

        Nothing is configured to deliver it, so it stays pending."""
        return self.rpc('{:ok, [_]} = AtMcp.Inbound.Store.accept([%%{matched_did: "did:plc:%s", '
                        'uri: "at://did:plc:someone/app.bsky.feed.post/%d", reasons: ["mention"]}]); '
                        'IO.puts(:accepted)' % (name, n))

    def checkpoint(self, name, n):
        self.rpc('AtMcp.Inbound.Store.checkpoint(%d); '
                 'AtMcp.Inbound.Store.checkpoint_notifications("did:plc:%s", %d); IO.puts(:checkpointed)' % (n, name, n))

    def checkpoints(self, name):
        return self.rpc('IO.puts(Jason.encode!([AtMcp.Inbound.Store.status().cursor, '
                        'AtMcp.Inbound.Store.notification_checkpoint("did:plc:%s")]))' % name)

    def queued_uris(self):
        return self.rpc('IO.puts(Jason.encode!(AtMcp.Inbound.Store |> :sys.get_state() |> '
                        'Map.fetch!(:data) |> Map.fetch!(:pending) |> Map.values() |> '
                        'Enum.map(& &1.event.uri) |> Enum.sort()))')

    def pending(self):
        return int(self.rpc("IO.puts(AtMcp.Inbound.Store.status().pending)"))

    def mcp(self, authorization=None):
        """The HTTP status of an MCP initialize request to the endpoint."""
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "at_mcp-release-check", "version": "0"}}}).encode()
        headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
        if authorization:
            headers["Authorization"] = authorization
        request = urllib.request.Request("http://127.0.0.1:%d/mcp" % self.mcp_port, data=body, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return response.status
        except urllib.error.HTTPError as error:
            return error.code


class Foreground:
    """What the example plist runs, as a child of this script."""

    pack_owner = []

    def check_owner(self, target):
        pass

    def __init__(self, root, examples):
        self.examples = pathlib.Path(examples)
        self.root = pathlib.Path(root)
        self.prefix = self.root / "at_mcp"
        # A space in the path, as `~/Library/Application Support` has: the
        # accounts file's line in the environment file must be quoted to
        # survive a shell, and the plist must pass the file's path whole.
        self.etc = self.root / "Application Support" / "AtMcp"
        self.state = self.etc / "state"
        self.home = self.root / "home"
        self.home.mkdir(parents=True, exist_ok=True)
        self.log = self.root / "at_mcp.log"
        self.service = None
        # The service and the commands see only what a login session would
        # give them; everything else comes from the environment file.
        self.env = {"HOME": str(self.home), "PATH": os.environ.get("PATH", "/usr/bin:/bin")}
        if "LANG" in os.environ:
            self.env["LANG"] = os.environ["LANG"]

    def run(self, argv):
        subprocess.run(argv, check=True)

    def make_private_dir(self, path):
        path.mkdir(parents=True, exist_ok=True)
        path.chmod(0o700)

    def make_state_dir(self):
        self.make_private_dir(self.state)

    def write_private(self, path, text):
        path.write_text(text)
        path.chmod(0o600)

    def as_service_user(self, argv, timeout, stdin=None):
        return subprocess.run(argv, env=self.env, text=True, capture_output=True, timeout=timeout, input=stdin)

    def unit_argv(self):
        """ProgramArguments of rel/examples/li.example.at_mcp.plist, with its paths."""
        plist = (self.examples / "li.example.at_mcp.plist").read_text()
        plist = plist.replace("bin/at_mcp", "bin/" + getattr(self, "release_command", "at_mcp"))
        assert plist.count("<string>/bin/sh</string>") == 1, plist
        start = plist.index("<key>ProgramArguments</key>")
        body = plist[plist.index("<array>", start) + len("<array>"):plist.index("</array>", start)]
        strings = [s.split("</string>")[0] for s in body.split("<string>")[1:]]
        mapping = {"/Users/you/at_mcp/at_mcp.env": str(self.etc / "at_mcp.env"), "/Users/you/at_mcp": str(self.prefix)}
        out = []
        for s in strings:
            for old, new in mapping.items():
                s = s.replace(old, new)
            out.append(s.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">"))
        return out

    def start(self):
        assert self.service is None or self.service.poll() is not None
        log = open(self.log, "ab")
        self.service = subprocess.Popen(
            self.unit_argv(), env=self.env, cwd=str(self.prefix), stdin=subprocess.DEVNULL,
            stdout=log, stderr=log, start_new_session=True,
        )
        log.close()

    def pid(self):
        return self.service.pid

    def exited(self, timeout=30):
        """The exit status of the process the unit started, once it exits."""
        return self.service.wait(timeout=timeout)

    def stop(self):
        """SIGTERM to the process the unit started, as launchd's bootout sends."""
        if self.service is None or self.service.poll() is not None:
            return None
        self.service.send_signal(signal.SIGTERM)
        return self.service.wait(timeout=60)

    def restart(self):
        self.stop()
        self.start()

    def logs(self):
        return self.log.read_text(errors="replace") if self.log.exists() else ""

    def cleanup(self):
        if self.service and self.service.poll() is None:
            os.killpg(self.service.pid, signal.SIGTERM)
            try:
                self.service.wait(timeout=30)
            except subprocess.TimeoutExpired:
                os.killpg(self.service.pid, signal.SIGKILL)
                self.service.wait()
        shutil.rmtree(self.root, ignore_errors=True)


class Systemd:
    """The example systemd unit, installed for real. Root, disposable machine."""

    unit = "at_mcp"

    # The owner a tarball packed on a CI runner records (the runner's uid), which
    # README's `tar --no-same-owner` must not carry onto the files root unpacks.
    pack_owner = ["--owner=1001", "--group=1001", "--numeric-owner"]

    def check_owner(self, target):
        wrong = [str(p) for p in [target, *target.rglob("*")]
                 if not p.is_symlink() and (p.lstat().st_uid, p.lstat().st_gid) != (0, 0)]
        assert not wrong, ("unpacked files not owned by root", wrong[:3])

    def __init__(self, examples):
        assert os.environ.get("CI") == "true", "the systemd check runs only on a disposable CI runner"
        assert os.geteuid() == 0, "the systemd check runs as root on a disposable machine"
        self.examples = pathlib.Path(examples)
        self.prefix = pathlib.Path("/opt/at_mcp")
        self.etc = pathlib.Path("/etc/at_mcp")
        self.state = pathlib.Path("/var/lib/at_mcp")
        for path in (self.prefix, self.etc, self.state, pathlib.Path("/etc/systemd/system/at_mcp.service")):
            assert not path.exists(), "%s exists; this check wants a machine with no AtMcp" % path
        subprocess.run(["useradd", "--system", "--home-dir", str(self.state), "--shell", "/usr/sbin/nologin", "at_mcp"], check=True)

    def run(self, argv):
        subprocess.run(argv, check=True)

    def make_private_dir(self, path):
        subprocess.run(["install", "-d", "-o", "root", "-g", "at_mcp", "-m", "750", str(path)], check=True)

    def make_state_dir(self):
        # The unit's StateDirectory= makes it when the service first starts.
        pass

    def write_private(self, path, text):
        path.write_text(text)
        shutil.chown(path, "root", "at_mcp")
        path.chmod(0o640)

    def as_service_user(self, argv, timeout, stdin=None):
        # From /, since the at_mcp user may not be able to read this checkout.
        return subprocess.run(["sudo", "-u", "at_mcp", "-H"] + argv, cwd="/", text=True, capture_output=True,
                              timeout=timeout, input=stdin)

    def install_unit(self):
        unit = (self.examples / "at_mcp.service").read_text()
        unit = unit.replace("bin/at_mcp", "bin/" + getattr(self, "release_command", "at_mcp"))
        pathlib.Path("/etc/systemd/system/at_mcp.service").write_text(unit)
        subprocess.run(["systemctl", "daemon-reload"], check=True)

    def start(self):
        subprocess.run(["systemctl", "start", self.unit], check=True)

    def pid(self):
        out = subprocess.run(["systemctl", "show", "-p", "MainPID", "--value", self.unit],
                             check=True, text=True, capture_output=True)
        return int(out.stdout.strip())

    def check_hides_other_processes(self):
        """The unit's ProtectProc=invisible, as the service sees it: the service's
        user, in the service's own mount namespace, cannot read another user's
        command line (PID 1's here), though the same user outside the unit can.
        Command lines are read and discarded, never printed: one holds the cookie."""
        name = subprocess.run(["systemctl", "show", "-p", "User", "--value", self.unit],
                              check=True, text=True, capture_output=True).stdout.strip()
        assert name, "the unit names no User=; the check needs the service's user"
        user = pwd.getpwnam(name)
        pid = self.pid()

        def readable(argv, target):
            out = subprocess.run(argv + ["cat", "/proc/%d/cmdline" % target], cwd="/", capture_output=True)
            return out.returncode == 0 and len(out.stdout) > 0

        inside = ["nsenter", "--target", str(pid), "--mount",
                  "--setuid", str(user.pw_uid), "--setgid", str(user.pw_gid)]
        assert readable(["sudo", "-u", name], 1), "the check cannot tell: PID 1 is hidden outside the unit too"
        assert readable(inside, pid), "the service's user cannot read its own process inside the unit"
        assert not readable(inside, 1), "the service can read other users' command lines; the unit lacks ProtectProc=invisible"

    def stop(self):
        subprocess.run(["systemctl", "stop", self.unit], check=True)
        state = subprocess.run(["systemctl", "show", "-p", "ActiveState", "--value", self.unit],
                               text=True, capture_output=True).stdout.strip()
        assert state in ("inactive", "failed"), state
        result = subprocess.run(["systemctl", "show", "-p", "ExecMainStatus", "--value", self.unit],
                                text=True, capture_output=True).stdout.strip()
        return int(result or 0)

    def restart(self):
        subprocess.run(["systemctl", "restart", self.unit], check=True)

    def logs(self):
        return subprocess.run(["journalctl", "-u", self.unit, "--no-pager", "-n", "400"],
                              text=True, capture_output=True).stdout

    def cleanup(self):
        subprocess.run(["systemctl", "stop", self.unit])


class Launchd:
    """The example plist, installed for real in the user's launchd domain. CI only."""

    label = "li.example.at_mcp"
    pack_owner = []

    def check_owner(self, target):
        pass

    def __init__(self, examples):
        assert os.environ.get("CI") == "true", "the launchd check runs only on a disposable CI runner"
        self.examples = pathlib.Path(examples)
        home = pathlib.Path.home()
        self.prefix = home / "at_mcp"
        self.etc = self.prefix
        self.state = self.prefix / "state"
        self.log = home / "Library/Logs/AtMcp/at_mcp.log"
        self.plist = home / "Library/LaunchAgents" / (self.label + ".plist")
        for path in (self.prefix, self.plist):
            assert not path.exists(), "%s exists; this check wants a machine with no AtMcp" % path
        self.domain = "gui/%d" % os.getuid()
        self.target = "%s/%s" % (self.domain, self.label)
        self.env = {"HOME": str(home), "PATH": os.environ.get("PATH", "/usr/bin:/bin")}

    def run(self, argv):
        subprocess.run(argv, check=True)

    def make_private_dir(self, path):
        path.mkdir(parents=True, exist_ok=True)
        path.chmod(0o700)

    def make_state_dir(self):
        # Operations: mkdir -m 700 -p ~/at_mcp/state ~/Library/Logs/AtMcp
        self.make_private_dir(self.state)
        self.log.parent.mkdir(parents=True, exist_ok=True)

    def write_private(self, path, text):
        path.write_text(text)
        path.chmod(0o600)

    def as_service_user(self, argv, timeout, stdin=None):
        return subprocess.run(argv, env=self.env, text=True, capture_output=True, timeout=timeout, input=stdin)

    def install_unit(self):
        # Operations: sed "s|/Users/you|$HOME|g" ... > ~/Library/LaunchAgents/li.example.at_mcp.plist
        self.plist.parent.mkdir(parents=True, exist_ok=True)
        text = (self.examples / "li.example.at_mcp.plist").read_text()
        text = text.replace("bin/at_mcp", "bin/" + getattr(self, "release_command", "at_mcp"))
        self.plist.write_text(text.replace("/Users/you", str(pathlib.Path.home())))

    def launchctl(self, *args, check=True):
        return subprocess.run(["launchctl"] + list(args), text=True, capture_output=True, check=check)

    def start(self):
        self.launchctl("bootstrap", self.domain, str(self.plist))

    def printed(self):
        return self.launchctl("print", self.target, check=False)

    def pid(self):
        match = re.search(r"^\s*pid = (\d+)", self.printed().stdout, re.M)
        return int(match.group(1)) if match else None

    def stop(self):
        """bootout sends SIGTERM and waits; the exit status is launchd's record of it."""
        self.launchctl("bootout", self.target)
        poll(lambda: self.printed().returncode != 0)
        return 0

    def restart(self):
        # Operations: launchctl kickstart -k gui/$(id -u)/li.example.at_mcp
        before = self.pid()
        self.launchctl("kickstart", "-k", self.target)
        poll(lambda: self.pid() not in (None, before))

    def logs(self):
        return self.log.read_text(errors="replace") if self.log.exists() else ""

    def cleanup(self):
        self.launchctl("bootout", self.target, check=False)
