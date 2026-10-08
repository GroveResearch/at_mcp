"""Check the explicit Kite -> at_mcp default-path transition in fresh release VMs.

Usage: python3 scripts/rename_defaults_check.py KITE_RELEASE AT_MCP_RELEASE
No real account, home directory, or installed service is touched.
"""
import hashlib
import os
import pathlib
import subprocess
import sys
import tempfile

old, new = [pathlib.Path(p).resolve() for p in sys.argv[1:]]
with tempfile.TemporaryDirectory(prefix="at-mcp-defaults-") as root:
    env = {"HOME": root, "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
           "RELEASE_COOKIE": "disposable-rename-check"}

    def evaluate(release, name, expression, extra=None):
        return subprocess.run([str(release / "bin" / name), "eval", expression],
                              env={**env, **(extra or {})}, text=True, capture_output=True, timeout=30)

    def old_path(expression):
        result = evaluate(old, "kite", "IO.puts(" + expression + ")")
        assert result.returncode == 0, result.stderr
        path = pathlib.Path(result.stdout.strip().splitlines()[-1])
        assert path.is_relative_to(root), path
        return path

    accounts = old_path("Kite.AccountConfig.path()")
    state = old_path("Kite.Inbound.Store.default_dir()")
    fresh = evaluate(new, "at_mcp", "IO.puts(AtMcp.AccountConfig.path())")
    assert fresh.returncode == 0, fresh.stderr
    assert "at_mcp" in fresh.stdout

    accounts.parent.mkdir(parents=True, exist_ok=True)
    accounts.write_text('{"version":1,"accounts":[]}')
    accounts.chmod(0o600)
    state.mkdir(parents=True, exist_ok=True)
    for expression, key, path in [("AtMcp.AccountConfig.path()", "AT_MCP_ACCOUNTS_FILE", accounts),
                                   ("AtMcp.Inbound.Store.default_dir()", "AT_MCP_STATE_DIR", state)]:
        refused = evaluate(new, "at_mcp", expression)
        assert refused.returncode != 0, "old default silently ignored"
        assert key + "=" + str(path) in refused.stderr, refused.stderr
        selected = evaluate(new, "at_mcp", "IO.puts(" + expression + ")", {key: str(path)})
        assert selected.returncode == 0 and str(path) in selected.stdout, selected.stderr

    # The stdio command has its own account-scoped default. Its diagnostic must
    # point at the old leaf, not the shared root (which would reset that quota).
    service, handle = "http://127.0.0.1:1", "fixture.example"
    digest = hashlib.sha256((service + "\n" + handle).encode()).hexdigest()
    leaf = state / "stdio" / digest
    leaf.mkdir(parents=True)
    stdio = subprocess.run([str(new / "bin" / "at_mcp-stdio")], input="", text=True,
                           env={**env, "AT_MCP_SERVICE": service, "AT_MCP_HANDLE": handle,
                                "AT_MCP_APP_PASSWORD": "fixture-password"},
                           capture_output=True, timeout=30)
    assert stdio.returncode != 0
    assert "AT_MCP_STATE_DIR=" + str(leaf) in stdio.stderr, stdio.stderr
    print("fresh default works; old accounts/shared/stdio paths require explicit selection")
