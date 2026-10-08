#!/usr/bin/env python3
"""Exercise a built Hex archive in a separate application, never the checkout.

This is a local artifact proof, not an exercise of a published Hex package.
Only the package's released dependencies are fetched from Hex.
"""
import io
import os
import re
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

from support.release_run import FakePDS

archive = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="at-mcp-package-") as scratch:
    root = Path(scratch)
    package = root / "package"
    package.mkdir()
    with tarfile.open(archive) as outer:
        contents = outer.extractfile("contents.tar.gz").read()
    with tarfile.open(fileobj=io.BytesIO(contents), mode="r:gz") as inner:
        names = set(inner.getnames())
        for required in ["Makefile", "c_src/native_lock.c", "LICENSE",
                         "licenses/flock_ex/LICENSE", "licenses/flock_ex/NOTICE.md",
                         "licenses/lexicons/LICENSE.txt", "licenses/lexicons/LICENSE-MIT.txt",
                         "licenses/lexicons/LICENSE-APACHE.txt", "licenses/lexicons/NOTICE.md",
                         "lib/at_mcp/native_lock.ex"]:
            assert required in names, f"package missing {required}"
        repo = Path(__file__).resolve().parent.parent
        for source in (repo / "licenses").rglob("*"):
            if source.is_file():
                relative = source.relative_to(repo).as_posix()
                assert inner.extractfile(relative).read() == source.read_bytes(), f"package notice mismatch: {relative}"
        assert any(name.startswith("priv/lexicons/") for name in names)
        assert not any(name.endswith((".so", ".beam")) for name in names), "host binaries in package"
        inner.extractall(package, filter="data")
    consumer = root / "consumer"
    (consumer / "config").mkdir(parents=True)
    (consumer / "mix.exs").write_text('''defmodule Consumer.MixProject do
  use Mix.Project
  def project, do: [app: :consumer, version: "0.1.0", deps: [{:at_mcp, path: "../package"}]]
  def application, do: [extra_applications: [:at_mcp]]
end
''')
    # Exercise the published embedding guide's actual config and first account
    # example, with only the state path and environment made disposable.
    guide = (package / "docs/embedding.md").read_text()
    blocks = re.findall(r"```elixir\n(.*?)```", guide, re.S)
    assert len(blocks) == 3, "expected dependency, config and account examples"
    config = blocks[1].replace('"/absolute/private/path/my-app/at_mcp"',
                               'System.fetch_env!("CONSUMER_STATE")')
    (consumer / "config/config.exs").write_text("import Config\n" + config)
    (consumer / "check.exs").write_text(
        'false = Map.has_key?(:ranch.info(), :at_mcp_http)\n' + blocks[2] + '''
"did:plc:agent.test" = profile.did
"did:plc:agent.test" = AtMcp.Effects.session_did(effects)
{:ok, post} = AtMcp.Effects.post(effects, "Hello from the unpacked package")
true = String.starts_with?(post.uri, "at://did:plc:agent.test/app.bsky.feed.post/")
IO.puts("package consumer: documented identity/profile/disconnect/reconnect plus post passed")
''')
    pds = FakePDS()
    try:
        # Keep build-tool paths/caches, never account or GitHub credentials.
        env = {key: os.environ[key] for key in ["PATH", "LANG"] if key in os.environ}
        home = root / "home"
        home.mkdir()
        env.update(HOME=str(home),
                   HEX_HOME=os.environ.get("HEX_HOME", str(Path.home() / ".hex")),
                   MIX_HOME=os.environ.get("MIX_HOME", str(Path.home() / ".mix")))
        env.update(CONSUMER_STATE=str(root / "state"), AT_MCP_SERVICE=pds.url,
                   AT_MCP_HANDLE="agent.test", AT_MCP_APP_PASSWORD="fixture-app-password",
                   PROTO_RUNE_PATH=str(root / "nonexistent-override-must-be-ignored"))
        subprocess.run(["mix", "deps.get"], cwd=consumer, env=env, check=True)
        subprocess.run(["mix", "run", "check.exs"], cwd=consumer, env=env, check=True)
        assert FakePDS.created == 1, "exactly one fixture write expected"
        assert (consumer / "_build/dev/lib/at_mcp/priv/native_lock.so").is_file()
    finally:
        pds.close()
print("LOCAL artifact proof passed; published Hex resolution remains untested")
