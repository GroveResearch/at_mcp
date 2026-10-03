"""Check the actual publication condition and shell, without GitHub mutations.

This intentionally understands only the workflow's small boolean condition,
not general YAML or GitHub expressions. A changed syntax fails for review.
"""
import ast
import itertools
import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest

WORKFLOW = Path(__file__).resolve().parents[1] / '.github/workflows/check.yml'


def boolean(node):
    if isinstance(node, ast.Expression):
        return boolean(node.body)
    if isinstance(node, ast.Constant) and isinstance(node.value, (bool, str)):
        return node.value
    if isinstance(node, ast.BoolOp):
        values = [boolean(value) for value in node.values]
        if isinstance(node.op, ast.And):
            return all(values)
        if isinstance(node.op, ast.Or):
            return any(values)
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.Not):
        return not boolean(node.operand)
    if isinstance(node, ast.Compare) and len(node.ops) == 1 and isinstance(node.ops[0], ast.Eq):
        return boolean(node.left) == boolean(node.comparators[0])
    raise AssertionError('Unsupported publication condition syntax: ' + ast.dump(node))


class PlatformContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        workflow = WORKFLOW.read_text()
        parts = re.split(r'^  ([a-z_]+):\n', workflow.split('\njobs:\n', 1)[1], flags=re.M)
        cls.jobs = dict(zip(parts[1::2], parts[2::2]))
        cls.platforms = {}
        for name, block in cls.jobs.items():
            if 'uses: actions/upload-artifact@' in block:
                upload = block.split('uses: actions/upload-artifact@', 1)[1]
                cls.platforms[name] = re.search(r'^          name: (\S+)$', upload, re.M)[1]
        assert len(cls.platforms) == 2, 'This release promises two binary platforms'
        cls.publish = cls.jobs['publish']
        cls.condition = re.search(r'^    if: \$\{\{ (.*) \}\}$', cls.publish, re.M)[1]
        cls.shell = textwrap.dedent(cls.publish.split('        run: |\n', 1)[1])

    def test_only_a_tag_with_every_platform_success_can_publish(self):
        needs = re.search(r'^    needs: \[(.*)\]$', self.publish, re.M)[1]
        self.assertEqual(set(map(str.strip, needs.split(','))), set(self.platforms))
        # Empty means missing result; cancelled is also tested independently of
        # a platform's result. Dispatch on even a tag must never publish.
        statuses = ('success', 'failure', 'cancelled', 'skipped', '')
        for results in itertools.product(statuses, repeat=len(self.platforms)):
            for event, ref in [('push', 'refs/tags/v0.1.2'), ('push', 'refs/heads/main'),
                               ('workflow_dispatch', 'refs/tags/v0.1.2'),
                               ('workflow_dispatch', 'refs/heads/topic'),
                               ('pull_request', 'refs/pull/1/merge')]:
                for cancelled in (False, True):
                    expression = self.condition.replace('cancelled()', str(cancelled))
                    expression = expression.replace("startsWith(github.ref, 'refs/tags/v')",
                                                    str(ref.startswith('refs/tags/v')))
                    expression = expression.replace('github.event_name', repr(event))
                    for job, result in zip(self.platforms, results):
                        expression = expression.replace(f'needs.{job}.result', repr(result))
                    expression = expression.replace('&&', ' and ').replace('||', ' or ').replace('!', ' not ')
                    actual = boolean(ast.parse(expression.strip(), mode='eval'))
                    expected = (not cancelled and event == 'push' and ref.startswith('refs/tags/v')
                                and all(result == 'success' for result in results))
                    with self.subTest(results=results, event=event, ref=ref, cancelled=cancelled):
                        self.assertEqual(actual, expected)

    def test_missing_asset_stops_before_any_github_call(self):
        names = [f'at_mcp-0.1.2-{platform}.tar.gz{suffix}'
                 for platform in self.platforms.values() for suffix in ('', '.sha256')]
        for missing in [None, *names]:
            with self.subTest(missing=missing), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / 'artifacts').mkdir()
                for name in names:
                    if name != missing:
                        (root / 'artifacts' / name).write_text('fixture')
                # Intercept every gh call, including release view. The real
                # workflow shell must refuse incomplete inputs before this.
                gh = root / 'gh'
                gh.write_text('#!/bin/sh\necho "$*" >> "$CALLS"\nexit 0\n')
                gh.chmod(0o755)
                calls = root / 'calls'
                result = subprocess.run(['bash', '-c', self.shell], cwd=root, capture_output=True,
                    env={**os.environ, 'PATH': str(root) + os.pathsep + os.environ['PATH'],
                         'CALLS': str(calls), 'GITHUB_REF_NAME': 'v0.1.2', 'GITHUB_SHA': 'fixture',
                         'GITHUB_REPOSITORY': 'fixture/at_mcp', 'GITHUB_SERVER_URL': 'https://example.test',
                         'GITHUB_RUN_ID': '1', 'LINUX': 'success', 'MACOS': 'success'})
                if missing is None:
                    self.assertEqual(result.returncode, 0, result.stderr.decode())
                    self.assertIn('release upload', calls.read_text())
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(calls.exists(), 'Incomplete release reached gh')


if __name__ == '__main__':
    unittest.main()
