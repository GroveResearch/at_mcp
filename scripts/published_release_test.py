"""Hermetic checks for choosing release N, the release an upgrade check starts from."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import published_release as subject


RELEASE = [{"draft": False, "prerelease": False, "tag_name": "v0.1.3",
            "published_at": "2026-10-03", "assets": [{"name": "at_mcp-0.1.3-linux-x86_64.tar.gz"}]}]


class ReleaseNTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def test_release_built_from_the_commit_under_test_is_refused(self):
        old = self.root / "wrong-candidate"
        old.mkdir()
        (old / "BUILD").write_text("0.1.3-abcdef1")
        with patch.object(subject, "gh", return_value=json.dumps(RELEASE)), patch.object(subject, "tag_commit", return_value="other-tag-commit"), patch.object(subject.subprocess, "run"), patch.object(subject, "unpack", return_value=old):
            with self.assertRaisesRegex(SystemExit, "upgrade to itself"):
                subject.fetch("GroveResearch/at_mcp", "linux-x86_64", self.root, "abcdef123456")

    def test_no_eligible_release_is_a_failure(self):
        with patch.object(subject, "gh", return_value="[]"):
            with self.assertRaisesRegex(SystemExit, "no published release"):
                subject.fetch("GroveResearch/at_mcp", "linux-x86_64", self.root, "new-root")

    def test_a_failed_download_is_a_failure(self):
        with patch.object(subject, "gh", return_value=json.dumps(RELEASE)), patch.object(subject, "tag_commit", return_value="older"), patch.object(subject.subprocess, "run", side_effect=RuntimeError("download failed")):
            with self.assertRaisesRegex(RuntimeError, "download failed"):
                subject.fetch("GroveResearch/at_mcp", "linux-x86_64", self.root, "new-root")


if __name__ == "__main__":
    unittest.main()
