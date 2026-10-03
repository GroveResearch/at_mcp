#!/usr/bin/env python3
"""Check notice retention in an extracted binary, without starting its runtime."""
import hashlib
from pathlib import Path
import sys


def check(release: Path) -> None:
    notices = release / "licenses" / "bundled"
    apps = sorted(p.name for p in (release / "lib").iterdir())
    assert (notices / "APPLICATIONS").read_text().splitlines() == apps, "Bundled application inventory changed"
    manifest = (notices / "SHA256SUMS").read_text().splitlines()
    assert manifest, "Empty notice manifest"
    for line in manifest:
        digest, relative = line.split("  ", 1)
        path = notices / relative
        assert path.resolve().is_relative_to(notices.resolve()), relative
        assert hashlib.sha256(path.read_bytes()).hexdigest() == digest, f"Changed notice: {relative}"
    for app in apps:
        if not app.startswith(("at_mcp-", "kite-")):
            assert (notices / app).is_dir(), f"Missing notice directory: {app}"
    print(f"Bundled notices verified for {len(apps)} release applications")


if __name__ == "__main__":
    check(Path(sys.argv[1]))
