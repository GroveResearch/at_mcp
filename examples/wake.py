#!/usr/bin/env python3
"""Wake an agent when someone addresses its account.

A receiver for at_mcp's delivery (docs/delivery.md). It accepts the events a
long-running at_mcp service sends, keeps the ones whose reason you choose
(replies, mentions and quotes by default), waits until a burst has gone quiet,
then runs your command once, with a short summary of what arrived on its
standard input and in the AT_MCP_WAKE_SUMMARY environment variable.

    python3 wake.py --token-file ~/.config/at_mcp/receiver-token \\
        --command 'claude -p "Below is a list of new notifications on your account. Read each thread they belong to, and reply where you have something to say."'

Point the service at it with AT_MCP_DELIVERY_URL=http://127.0.0.1:4420/inbound
and AT_MCP_DELIVERY_TOKEN_FILE naming the same token file.

The receiver writes each event to the pending file before it acknowledges the
delivery, so events waiting for a wake survive a restart. It hands each event
to the command at most once: it removes the events from the pending file
before the command starts, and a run that exits non-zero is logged with the
events it was given, not run again with them. `claude -p` can exit non-zero
after it has replied, and a second run would reply twice. A repeat delivery of
an event that is still waiting is dropped. The script uses only Python's
standard library.
"""

import argparse
import hmac
import json
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def parse_args(argv):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--command", required=True, help="shell command to run on each wake")
    p.add_argument("--port", type=int, default=4420, help="port on 127.0.0.1 (default 4420)")
    auth = p.add_mutually_exclusive_group(required=True)
    auth.add_argument("--token-file", help="file holding the token at_mcp sends (required unless --no-token)")
    auth.add_argument("--no-token", action="store_true",
                      help="accept every request on the port, from any local process, without a token")
    p.add_argument("--reasons", default="reply,mention,quote",
                   help="comma-separated reasons that wake the agent (default reply,mention,quote)")
    p.add_argument("--quiet", type=float, default=30,
                   help="seconds without a new event before waking (default 30)")
    p.add_argument("--max-wait", type=float, default=300,
                   help="longest a waiting event is held before a wake starts, however busy it gets; "
                        "a command still running can extend it (default 300)")
    p.add_argument("--pending", default=default_pending(),
                   help="file holding events not yet handed to the command "
                        "(default $XDG_STATE_HOME/at_mcp/wake-pending.jsonl, "
                        "else ~/.local/state/at_mcp/wake-pending.jsonl)")
    args = p.parse_args(argv)
    args.pending = os.path.abspath(os.path.expanduser(args.pending))
    return args


def default_pending():
    state = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(state, "at_mcp", "wake-pending.jsonl")


def reasons_of(event):
    """An event's reasons, from polling (`reason`) or the stream (`reasons`, `kind`)."""
    found = set(event.get("reasons") or [])
    if event.get("reason"):
        found.add(event["reason"])
    kind = event.get("kind", "")
    if kind.startswith("inbound_") and kind != "inbound_notification":
        found.add(kind[len("inbound_"):])
    return found


def summarize(events):
    noun = "notification" if len(events) == 1 else "notifications"
    lines = [f"{len(events)} new {noun} for your account since the last wake:"]
    for e in events:
        who = e.get("author") or e.get("author_did") or "someone"
        what = "/".join(sorted(reasons_of(e))) or "event"
        text = " ".join((e.get("raw_text") or e.get("text") or "").split())
        if len(text) > 200:
            text = text[:199] + "…"
        line = f"- {what} from @{who}" if e.get("author") else f"- {what} from {who}"
        if text:
            line += f': "{text}"'
        line += f" ({e.get('uri')})"
        root = e.get("thread_root_uri")
        if root and root != e.get("uri"):
            line += f", in the thread that starts at {root}"
        lines.append(line)
    return "\n".join(lines) + "\n"


class Waker:
    def __init__(self, args):
        self.args = args
        self.reasons = {r.strip() for r in args.reasons.split(",") if r.strip()}
        self.lock = threading.Lock()
        self.running = threading.Lock()
        self.timer = None
        self.first_at = None
        os.makedirs(os.path.dirname(args.pending), mode=0o700, exist_ok=True)
        self.events = self._load()
        if self.events:
            self._schedule()

    def _load(self):
        try:
            with open(self.args.pending) as f:
                return [json.loads(line) for line in f if line.strip()]
        except FileNotFoundError:
            return []

    def _save(self):
        tmp = self.args.pending + ".tmp"
        with open(tmp, "w") as f:
            for e in self.events:
                f.write(json.dumps(e) + "\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, self.args.pending)

    def accept(self, event):
        """Keep an event if its reason wakes the agent. Called before answering 2xx."""
        if not reasons_of(event) & self.reasons:
            return
        key = (event.get("matched_did"), event.get("uri"))
        with self.lock:
            if any((e.get("matched_did"), e.get("uri")) == key for e in self.events):
                return
            self.events.append(event)
            self._save()
            if self.first_at is None:
                self.first_at = time.monotonic()
            self._schedule()

    # Each new event restarts the quiet period, up to --max-wait seconds after
    # the first waiting event, so a steady trickle of events still wakes the
    # agent. `floor` is the least delay: a wake that finds a command still
    # running waits a quiet period before it looks again, rather than
    # retrying at once while --max-wait has passed.
    def _schedule(self, floor=0):
        if self.timer:
            self.timer.cancel()
        first = self.first_at or time.monotonic()
        delay = min(self.args.quiet, max(0, first + self.args.max_wait - time.monotonic()))
        delay = max(delay, floor)
        self.timer = threading.Timer(delay, self.wake)
        self.timer.daemon = True
        self.timer.start()

    def wake(self):
        # One run at a time. Events arriving during a run wait for the next.
        if not self.running.acquire(blocking=False):
            with self.lock:
                self._schedule(floor=self.args.quiet)
            return
        try:
            # Handed over before the command starts, so neither a failed run
            # nor a restart during one gives the same events to a second run.
            with self.lock:
                events, self.events, self.timer, self.first_at = list(self.events), [], None, None
                if events:
                    self._save()
            if not events:
                return
            summary = summarize(events)
            env = dict(os.environ, AT_MCP_WAKE_SUMMARY=summary)
            result = subprocess.run(self.args.command, shell=True, input=summary, text=True, env=env)
            with self.lock:
                if result.returncode != 0:
                    uris = " ".join(str(e.get("uri")) for e in events)
                    print(f"wake: command exited {result.returncode} with {len(events)} events; "
                          f"not handing them over again: {uris}", file=sys.stderr, flush=True)
                if self.events and self.timer is None:
                    self.first_at = time.monotonic()
                    self._schedule()
        finally:
            self.running.release()


def handler(waker, token_file):
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            if token_file:
                # Read on each request, as at_mcp reads its copy, so the token
                # can change without a restart.
                with open(token_file) as f:
                    expected = "Bearer " + f.read().strip()
                given = self.headers.get("Authorization", "")
                if not hmac.compare_digest(given.encode(), expected.encode()):
                    return self.answer(401)
            try:
                length = int(self.headers.get("Content-Length", 0))
                event = json.loads(self.rfile.read(length))
                if not isinstance(event, dict):
                    raise ValueError("not an object")
            except ValueError:
                return self.answer(400)
            waker.accept(event)
            self.answer(204)

        def answer(self, status):
            self.send_response(status)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def log_message(self, *_):
            pass

    return Handler


def main(argv=None):
    args = parse_args(argv)
    waker = Waker(args)
    if args.no_token:
        print("wake: --no-token: accepting every request on the port without a token",
              file=sys.stderr, flush=True)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), handler(waker, args.token_file))
    print(f"wake: listening on http://127.0.0.1:{server.server_address[1]}/inbound", file=sys.stderr, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
