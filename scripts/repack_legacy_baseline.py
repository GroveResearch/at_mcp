"""Add reviewed notices to genuine Kite0.1.2 without changing executable bytes.

Usage: python3 scripts/repack_legacy_baseline.py PLATFORM ORIGINAL NOTICE_TREE OUTPUT
NOTICE_TREE contains only LICENSE and/or licenses/* at release-root paths.
The output is reproducible (zero timestamps and root ownership). Review its new
checksum before recording it in legacy_baseline.json. Original digests never
claim to describe this repack. This command does not upload anything.
"""
import copy
import gzip
import hashlib
import io
import json
from pathlib import Path
import sys
import tarfile

from published_release import LEGACY_MANIFEST


def repack(platform, original, notices, output):
    manifest = json.loads(LEGACY_MANIFEST.read_text())
    asset = manifest["assets"][platform]
    original_bytes = original.read_bytes()
    if hashlib.sha256(original_bytes).hexdigest() != asset["original_sha256"]:
        raise ValueError("original archive checksum mismatch")
    additions = {}
    for path in sorted(notices.rglob("*")):
        if path.is_symlink():
            raise ValueError("notice tree must contain ordinary files")
        if path.is_file():
            name = path.relative_to(notices).as_posix()
            if name != "LICENSE" and not name.startswith("licenses/"):
                raise ValueError("notice tree contains non-notice path: " + name)
            additions["kite-0.1.2/" + name] = path.read_bytes()
    if not additions:
        raise ValueError("empty notice tree")
    provenance = {"original_asset": original.name, "original_sha256": asset["original_sha256"],
                  "original_source_commit": "40a969ab7ac5bf0e588dfa86c16aee440c8bb8a1",
                  "build": manifest["build"], "change": "Added notices; every original file byte and mode retained.",
                  "added_notices": sorted(additions)}
    additions["kite-0.1.2/BASELINE_PROVENANCE.json"] = (json.dumps(provenance, indent=2) + "\n").encode()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(fileobj=io.BytesIO(original_bytes), mode="r:gz") as source:
        if source.extractfile("kite-0.1.2/BUILD").read().decode().strip() != manifest["build"]:
            raise ValueError("original BUILD mismatch")
        if additions.keys() & set(source.getnames()):
            raise ValueError("notice repack would overwrite an original file")
        with output.open("wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as zipped:
            with tarfile.open(fileobj=zipped, mode="w", format=tarfile.PAX_FORMAT) as target:
                for member in source:
                    entry = copy.copy(member)
                    entry.mtime = entry.uid = entry.gid = 0
                    entry.uname = entry.gname = ""
                    entry.pax_headers = {}
                    target.addfile(entry, source.extractfile(member) if member.isfile() else None)
                for name, content in sorted(additions.items()):
                    entry = tarfile.TarInfo(name)
                    entry.size, entry.mode = len(content), 0o644
                    target.addfile(entry, io.BytesIO(content))
    # Recompute from output, including file modes and symlink targets. A notice
    # repack is not permission to replace/rebuild any historical executable.
    with tarfile.open(original) as before, tarfile.open(output) as after:
        for member in before:
            copied = after.getmember(member.name)
            assert (member.type, member.mode, member.linkname) == (copied.type, copied.mode, copied.linkname)
            if member.isfile():
                assert before.extractfile(member).read() == after.extractfile(copied).read()
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_name(output.name + ".sha256").write_text(digest + "  " + output.name + "\n")
    print(digest + "  " + output.name)
    return digest


if __name__ == "__main__":
    platform, original, notices, output = sys.argv[1:]
    repack(platform, Path(original), Path(notices), Path(output))
