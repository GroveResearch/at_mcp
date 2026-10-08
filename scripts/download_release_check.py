#!/usr/bin/env python3
"""Run README download/install commands against disposable unauthenticated HTTP.

The downloaded release then serves official MCP clients. This does not assert
public URL availability or that a locally built Mac release is portable.
"""
from functools import partial
import hashlib
import http.server
import os
import platform
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading

release = Path(sys.argv[1]).resolve()
repo = Path(__file__).resolve().parent.parent
version = (release / "releases/start_erl.data").read_text().split()[1]
section = (repo / "README.md").read_text().split("### Fetch a release\n", 1)[1].split("## Connect a first account", 1)[0]
blocks = re.findall(r"```sh\n(.*?)```", section, re.S)
assert len(blocks) == 4, "expected Mac, Linux, download and install command blocks"
class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass
with tempfile.TemporaryDirectory(prefix="at-mcp-download-") as scratch:
    root = Path(scratch)
    assets = root / "assets" / ("v" + version)
    assets.mkdir(parents=True)
    target = "macos-arm64" if platform.system() == "Darwin" else "linux-x86_64"
    name = f"at_mcp-{version}-{target}.tar.gz"
    archive = assets / name
    with tarfile.open(archive, "w:gz") as out:
        out.add(release, arcname="at_mcp-" + version)
    checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
    (assets / (name + ".sha256")).write_text(f"{checksum}  {name}\n")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), partial(Quiet, directory=str(root / "assets")))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        platform_block = blocks[0] if target == "macos-arm64" else blocks[1]
        assert "PLATFORM=" + target in platform_block
        platform_block, replacements = re.subn(r"^VERSION=[^\n]+$", "VERSION=" + version,
                                               platform_block, flags=re.M)
        assert replacements == 1, "expected one README version assignment"
        commands = platform_block + "\n" + blocks[2].replace(
            "BASE_URL=https://github.com/GroveResearch/at_mcp/releases/download",
            "BASE_URL=http://127.0.0.1:" + str(server.server_port))
        install = blocks[3]
        home = root / "home"
        home.mkdir()
        env = {"PATH": os.environ["PATH"], "HOME": str(home), "TMPDIR": str(root)}
        subprocess.run(["sh", "-ec", commands + "\n" + install], env=env, check=True)
        downloaded = home / "at_mcp/current"
        assert (downloaded / "LICENSE").read_bytes() == (repo / "LICENSE").read_bytes()
        for source in (repo / "licenses").rglob("*"):
            if source.is_file():
                relative = source.relative_to(repo)
                assert (downloaded / relative).read_bytes() == source.read_bytes(), f"release notice mismatch: {relative}"
        subprocess.run([sys.executable, str(repo / "scripts/release_notices_check.py"), str(downloaded)], check=True)
        env.update(TEST_MCP_COMMAND=str(downloaded / "bin/at_mcp-stdio"), TEST_STDIO_RELEASE="1")
        for key in ["MCP_CLIENT_PATH", "MCP_SDK_PATH"]:
            env[key] = os.environ[key]
        subprocess.run(["node", str(repo / "test/support/stdio_sdk_probe.mjs")], env=env, check=True)
        # A tampered archive must stop before installation/repointing.
        shutil.rmtree(home / "at_mcp")
        checksum_file = assets / (name + ".sha256")
        checksum_file.unlink()
        missing = subprocess.run(["sh", "-ec", commands + "\n" + install], env=env, capture_output=True)
        assert missing.returncode != 0 and not (home / "at_mcp").exists(), "missing checksum must stop installation"
        checksum_file.write_text(f"{checksum}  {name}\n")
        archive.write_bytes(archive.read_bytes() + b"tampered")
        bad = subprocess.run(["sh", "-ec", commands + "\n" + install], env=env, capture_output=True)
        assert bad.returncode != 0 and not (home / "at_mcp").exists()
    finally:
        server.shutdown()
print("LOCAL unauthenticated download, checksum rejection and official MCP clients passed; public URL remains untested")
