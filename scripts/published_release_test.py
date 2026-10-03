"""Hermetic checks for choosing a real predecessor at the fresh-repo boundary."""
import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

import published_release as subject
import repack_legacy_baseline as repacker


def archive(build):
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode="w:gz") as out:
        for name, body in {"BUILD": build.encode(), "bin/kite": b"historical executable"}.items():
            entry = tarfile.TarInfo("kite-0.1.2/" + name)
            entry.size = len(body)
            out.addfile(entry, io.BytesIO(body))
    return data.getvalue()


class BaselineTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.content = archive("0.1.2-40a969a")
        self.manifest = {"tag": "legacy-kite-v0.1.2", "build": "0.1.2-40a969a",
                         "assets": {platform: {"name": f"kite-0.1.2-notices-{platform}.tar.gz",
                                               "sha256": hashlib.sha256(self.content).hexdigest()}
                                    for platform in ["linux-x86_64", "macos-arm64"]}}
        manifest = self.root / "baseline.json"
        manifest.write_text(json.dumps(self.manifest))
        self.manifest_path = manifest
        patcher = patch.object(subject, "LEGACY_MANIFEST", manifest)
        patcher.start()
        self.addCleanup(patcher.stop)

    def fetch(self, platform="linux-x86_64", sha="new-root"):
        return subject.fetch_baseline("GroveResearch/at_mcp", platform, self.root / platform, sha)

    def test_both_platforms_use_same_public_repo_and_verified_historical_build(self):
        for platform in self.manifest["assets"]:
            with patch.object(subject.urllib.request, "urlopen", return_value=io.BytesIO(self.content)) as request:
                old = self.fetch(platform)
            self.assertEqual((old / "BUILD").read_text(), "0.1.2-40a969a")
            self.assertEqual(request.call_args.args, (
                "https://github.com/GroveResearch/at_mcp/releases/download/legacy-kite-v0.1.2/"
                + self.manifest["assets"][platform]["name"],))

    def test_absent_predecessor_uses_explicit_baseline_not_tag_identity(self):
        with patch.object(subject, "gh", return_value="[]"), patch.object(subject, "fetch_baseline", return_value="verified-old") as fallback:
            subject.fetch("GroveResearch/at_mcp", "linux-x86_64", self.root, "new-root")
        fallback.assert_called_once()

    def test_missing_manifest_or_unsupported_platform_is_a_failure(self):
        with self.assertRaises(KeyError):
            self.fetch(platform="unknown")
        self.manifest_path.unlink()
        with self.assertRaises(FileNotFoundError):
            self.fetch()

    def test_missing_asset_is_a_failure(self):
        with patch.object(subject.urllib.request, "urlopen", side_effect=HTTPError("url", 404, "missing", {}, None)):
            with self.assertRaises(HTTPError):
                self.fetch()

    def test_checksum_mismatch_never_unpacks(self):
        with patch.object(subject.urllib.request, "urlopen", return_value=io.BytesIO(self.content + b"changed")):
            with self.assertRaisesRegex(ValueError, "checksum"):
                self.fetch()
        self.assertFalse((self.root / "linux-x86_64").exists())

    def test_correct_checksum_but_wrong_build_is_rejected(self):
        content = archive("0.1.2-candidate")
        self.manifest["assets"]["linux-x86_64"]["sha256"] = hashlib.sha256(content).hexdigest()
        self.manifest_path.write_text(json.dumps(self.manifest))
        with patch.object(subject.urllib.request, "urlopen", return_value=io.BytesIO(content)):
            with self.assertRaisesRegex(ValueError, "BUILD"):
                self.fetch()

    def test_candidate_cannot_be_its_own_baseline(self):
        with patch.object(subject.urllib.request, "urlopen") as request:
            with self.assertRaisesRegex(ValueError, "candidate itself"):
                self.fetch(sha="40a969ab7ac5bf0e588dfa86c16aee440c8bb8a1")
        request.assert_not_called()

    def test_ordinary_release_candidate_artifact_is_still_refused(self):
        release = [{"draft": False, "prerelease": False, "tag_name": "v0.1.3",
                    "published_at": "2026-10-03", "assets": [{"name": "at_mcp-0.1.3-linux-x86_64.tar.gz"}]}]
        old = self.root / "wrong-candidate"
        old.mkdir()
        (old / "BUILD").write_text("0.1.3-abcdef1")
        with patch.object(subject, "gh", return_value=json.dumps(release)), patch.object(subject, "tag_commit", return_value="other-tag-commit"), patch.object(subject.subprocess, "run"), patch.object(subject, "unpack", return_value=old), patch.object(subject, "fetch_baseline") as fallback:
            with self.assertRaisesRegex(SystemExit, "upgrade to itself"):
                subject.fetch("GroveResearch/at_mcp", "linux-x86_64", self.root, "abcdef123456")
        fallback.assert_not_called()

    def test_notice_repack_preserves_old_files_and_has_its_own_reproducible_digest(self):
        original = self.root / "original.tar.gz"
        original.write_bytes(self.content)
        self.manifest["assets"]["linux-x86_64"]["original_sha256"] = hashlib.sha256(self.content).hexdigest()
        self.manifest_path.write_text(json.dumps(self.manifest))
        notices = self.root / "notices"
        notices.mkdir()
        (notices / "LICENSE").write_text("fixture notice")
        with patch.object(repacker, "LEGACY_MANIFEST", self.manifest_path):
            first = repacker.repack("linux-x86_64", original, notices, self.root / "first.tar.gz")
            second = repacker.repack("linux-x86_64", original, notices, self.root / "second.tar.gz")
        self.assertEqual(first, second)
        self.assertNotEqual(first, hashlib.sha256(self.content).hexdigest())
        with tarfile.open(self.root / "first.tar.gz") as contents:
            self.assertEqual(contents.extractfile("kite-0.1.2/bin/kite").read(), b"historical executable")
            self.assertEqual(contents.extractfile("kite-0.1.2/BUILD").read(), b"0.1.2-40a969a")
            provenance = json.load(contents.extractfile("kite-0.1.2/BASELINE_PROVENANCE.json"))
            self.assertEqual(provenance["original_sha256"], hashlib.sha256(self.content).hexdigest())
        (notices / "bin").mkdir()
        (notices / "bin/kite").write_text("replacement executable")
        with patch.object(repacker, "LEGACY_MANIFEST", self.manifest_path):
            with self.assertRaisesRegex(ValueError, "non-notice"):
                repacker.repack("linux-x86_64", original, notices, self.root / "bad.tar.gz")

    def test_ordinary_predecessor_failure_never_falls_back(self):
        release = [{"draft": False, "prerelease": False, "tag_name": "v0.1.3",
                    "published_at": "2026-10-03", "assets": [{"name": "at_mcp-0.1.3-linux-x86_64.tar.gz"}]}]
        with patch.object(subject, "gh", return_value=json.dumps(release)), patch.object(subject, "tag_commit", return_value="older"), patch.object(subject.subprocess, "run", side_effect=RuntimeError("download failed")), patch.object(subject, "fetch_baseline") as fallback:
            with self.assertRaisesRegex(RuntimeError, "download failed"):
                subject.fetch("GroveResearch/at_mcp", "linux-x86_64", self.root, "new-root")
        fallback.assert_not_called()


if __name__ == "__main__":
    unittest.main()
