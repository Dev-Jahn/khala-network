#!/usr/bin/env python3
"""Drive the khala channel MCP child over stdio for H21."""

import argparse
import glob
import json
import os
import select
import socket
import subprocess
import time


def wait_until(predicate, message: str, timeout: float = 5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.05)
    raise AssertionError(message)


def read_json(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def rewrite_registry(path: str, *, pid: int | None = None, session_id: str | None = None) -> None:
    entry = read_json(path)
    if pid is not None:
        entry["pid"] = pid
    if session_id is not None:
        entry["sessionId"] = session_id
    temporary = f"{path}.tmp"
    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump(entry, handle)
    os.replace(temporary, path)


class Client:
    def __init__(self, child: subprocess.Popen, writer):
        self.child = child
        self.writer = writer
        assert child.stdout is not None

    def send(self, message: dict) -> None:
        encoded = json.dumps(message, separators=(",", ":")) + "\n"
        if isinstance(self.writer, socket.socket):
            self.writer.sendall(encoded.encode("utf-8"))
        else:
            self.writer.write(encoded)
            self.writer.flush()

    def receive(self, timeout: float = 5.0) -> dict:
        assert self.child.stdout is not None
        ready, _, _ = select.select([self.child.stdout], [], [], timeout)
        if not ready:
            raise AssertionError("timed out waiting for MCP output")
        line = self.child.stdout.readline()
        if not line:
            raise AssertionError(f"channel child exited early with {self.child.poll()}")
        return json.loads(line)

    def response(self, request_id: int) -> dict:
        while True:
            message = self.receive()
            if message.get("id") == request_id:
                return message

    def close_input(self) -> None:
        self.writer.close()


def spawn_child(args, stderr, *, socket_stdin: bool = False) -> Client:
    parent_socket = None
    child_socket = None
    stdin = subprocess.PIPE
    if socket_stdin:
        parent_socket, child_socket = socket.socketpair()
        stdin = child_socket
    child_env = os.environ.copy()
    if args.child_session_id is not None:
        child_env["CLAUDE_CODE_SESSION_ID"] = args.child_session_id
    if args.child_project_dir is not None:
        child_env["CLAUDE_PROJECT_DIR"] = args.child_project_dir
    if args.child_sessions_dir is not None:
        child_env["KHALA_CLAUDE_SESSIONS_DIR"] = args.child_sessions_dir
    child_env["KHALA_CHANNEL_ANCESTRY_STOP_PID"] = str(os.getpid())
    child = subprocess.Popen(
        [args.bun, args.server],
        stdin=stdin,
        stdout=subprocess.PIPE,
        stderr=stderr,
        text=True,
        bufsize=1,
        env=child_env,
        cwd=args.cwd,
    )
    if child_socket is not None:
        child_socket.close()
        return Client(child, parent_socket)
    assert child.stdin is not None
    return Client(child, child.stdin)


def initialize(client: Client, capabilities: dict | None = None) -> None:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-06-18",
                "capabilities": capabilities or {},
                "clientInfo": {"name": "khala-h21", "version": "1"},
            },
        }
    )
    initialized = client.response(1)
    assert initialized["result"]["serverInfo"]["name"] == "khala", initialized
    assert initialized["result"]["serverInfo"]["version"] == "0.8.2", initialized
    assert "claude/channel" in initialized["result"]["capabilities"]["experimental"]
    client.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    client.send({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
    listed = client.response(2)
    assert {tool["name"] for tool in listed["result"]["tools"]} == {
        "khala_drain",
        "khala_reply",
    }, listed


def registered_socket(registration_path: str, child_pid: int):
    registration = read_json(registration_path)
    channel_socket = registration.get("channelSocket")
    if (
        channel_socket
        and registration.get("channelPID") == child_pid
        and registration.get("channelPIDStart")
        and registration.get("channelVerified") is True
        and os.path.exists(channel_socket)
    ):
        return channel_socket
    return None


def assert_registration_cleared(registration_path: str, channel_socket: str | None = None) -> bool:
    registration = read_json(registration_path)
    return (
        not registration.get("channelSocket")
        and not registration.get("channelPID")
        and not registration.get("channelPIDStart")
        and not registration.get("channelVerified")
        and (channel_socket is None or not os.path.exists(channel_socket))
    )


def ring(client: Client, channel_socket: str, content: str) -> None:
    request = {
        "v": 1,
        "content": content,
        "meta": {
            "from": "reel@bw2",
            "subject": "H21 reply",
            "pending": "1",
            "generation": "h21-generation",
            "unsafe-key": "drop me",
            "unsafe_value": "<bad>\"\nvalue",
        },
    }
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(5)
        connection.connect(channel_socket)
        connection.sendall(json.dumps(request).encode("utf-8") + b"\n")
        reply = b""
        while b"\n" not in reply:
            reply += connection.recv(65536)
    assert json.loads(reply.split(b"\n", 1)[0]) == {"ok": True}

    notification = client.receive()
    assert notification["method"] == "notifications/claude/channel", notification
    params = notification["params"]
    assert params["content"] == request["content"]
    assert params["meta"]["from"] == "reel@bw2"
    assert params["meta"]["generation"] == "h21-generation"
    assert "unsafe-key" not in params["meta"]
    assert all(character not in params["meta"]["unsafe_value"] for character in '<>"\n')


def run_full(args, stderr) -> None:
    client = spawn_child(args, stderr)
    child = client.child
    try:
        capabilities = {"experimental": {"claude/channel": {}}} if args.client_channel_marker else {
            "elicitation": {"form": {}},
            "roots": {"listChanged": True},
        }
        initialize(client, capabilities)
        if args.late_session_id:
            assert child.poll() is None, "channel child exited before the resumed session id appeared"
            time.sleep(3)
            rewrite_registry(args.registry_pid_file, session_id=args.late_session_id)

        channel_socket = wait_until(
            lambda: registered_socket(args.registration, child.pid),
            "channel child did not register and bind its socket",
            timeout=10,
        )
        assert os.path.basename(channel_socket).endswith(".sock")

        client.send(
            {
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/call",
                "params": {"name": "khala_drain", "arguments": {}},
            }
        )
        drained = client.response(3)
        assert not drained["result"].get("isError", False), drained
        assert "body from H21 inbox" in drained["result"]["content"][0]["text"]
        letter_name = "1700000000.1.8.sender@alpha"
        assert not os.path.exists(os.path.join(args.inbox, "new", letter_name))
        assert os.path.exists(os.path.join(args.inbox, "cur", letter_name))

        ring(client, channel_socket, "KHALA-CONDUIT/1\npending: 1\ngeneration: h21-generation")

        reply_to = "1700000000.1.9.sender@alpha"
        client.send(
            {
                "jsonrpc": "2.0",
                "id": 4,
                "method": "tools/call",
                "params": {
                    "name": "khala_reply",
                    "arguments": {
                        "to": "sender@alpha",
                        "text": "reply from H21",
                        "subject": "Re: H21",
                        "reply_to": reply_to,
                    },
                },
            }
        )
        tool_reply = client.response(4)
        assert not tool_reply["result"].get("isError", False), tool_reply
        letter_id = tool_reply["result"]["content"][0]["text"].strip()
        letter_path = os.path.join(args.outbox, letter_id)
        wait_until(lambda: os.path.isfile(letter_path), "khala_reply wrote no outbox letter")
        with open(letter_path, encoding="utf-8") as letter_file:
            letter = letter_file.read()
        assert f"In-Reply-To: {reply_to}\n" in letter
        assert "Subject: Re: H21\n" in letter
        assert letter.endswith("\nreply from H21\n")

        client.close_input()
        child.wait(timeout=8)
        assert child.returncode == 0
        wait_until(
            lambda: assert_registration_cleared(args.registration, channel_socket),
            "channel shutdown did not clear registration and socket",
        )
    finally:
        if child.poll() is None:
            child.terminate()
            child.wait(timeout=5)


def run_tools_only(args, stderr) -> None:
    client = spawn_child(args, stderr)
    child = client.child
    tools_only_line = "session not channel-enabled; tools only, doorbell stays on the socket path"
    try:
        initialize(client, {"elicitation": {"form": {}}, "roots": {"listChanged": True}})

        def tools_only_logged():
            try:
                with open(args.stderr, encoding="utf-8") as log_file:
                    return tools_only_line in log_file.read()
            except FileNotFoundError:
                return False

        wait_until(tools_only_logged, "channel child did not enter tools-only state", timeout=5)
        time.sleep(0.5)
        registration = read_json(args.registration)
        assert not registration.get("channelSocket"), registration
        assert not registration.get("channelPID"), registration
        assert not registration.get("channelPIDStart"), registration
        assert not registration.get("channelVerified"), registration
        assert not glob.glob(os.path.join(args.channels_dir, "*.sock"))

        client.send(
            {
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/call",
                "params": {"name": "khala_drain", "arguments": {}},
            }
        )
        drained = client.response(3)
        assert not drained["result"].get("isError", False), drained
        assert "body from H21 inbox" in drained["result"]["content"][0]["text"]

        client.send(
            {
                "jsonrpc": "2.0",
                "id": 4,
                "method": "tools/call",
                "params": {
                    "name": "khala_reply",
                    "arguments": {"to": "sender@alpha", "text": "tools-only reply"},
                },
            }
        )
        replied = client.response(4)
        assert not replied["result"].get("isError", False), replied
        letter_id = replied["result"]["content"][0]["text"].strip()
        wait_until(
            lambda: os.path.isfile(os.path.join(args.outbox, letter_id)),
            "tools-only khala_reply wrote no outbox letter",
        )

        client.close_input()
        child.wait(timeout=8)
        assert child.returncode == 0
        with open(args.stderr, encoding="utf-8") as log_file:
            assert log_file.read().count(tools_only_line) == 1
    finally:
        if child.poll() is None:
            child.terminate()
            child.wait(timeout=5)


def run_orphan(args, stderr) -> None:
    client = spawn_child(args, stderr, socket_stdin=True)
    child = client.child
    try:
        initialize(client, {"elicitation": {"form": {}}, "roots": {"listChanged": True}})
        time.sleep(2)
        client.close_input()
        try:
            child.wait(timeout=8)
        except subprocess.TimeoutExpired as error:
            raise AssertionError("channel child stayed alive after socketpair stdin EOF") from error
        assert child.returncode == 0, child.returncode
        for registration in filter(None, (args.registration, args.registration_2)):
            assert assert_registration_cleared(registration)
        assert not glob.glob(os.path.join(args.channels_dir, "*.sock"))
    finally:
        if child.poll() is None:
            child.terminate()
            child.wait(timeout=5)


def run_reattach(args, stderr) -> None:
    assert args.registration_2 and args.next_session_id
    client = spawn_child(args, stderr)
    child = client.child
    try:
        initialize(client, {"elicitation": {"form": {}}, "roots": {"listChanged": True}})
        old_socket = wait_until(
            lambda: registered_socket(args.registration, child.pid),
            "channel child did not make its initial attachment",
            timeout=10,
        )
        ring(client, old_socket, "H21c first attachment")

        rewrite_registry(args.registry_pid_file, session_id=args.next_session_id)

        def moved():
            new_socket = registered_socket(args.registration_2, child.pid)
            if new_socket and assert_registration_cleared(args.registration, old_socket):
                return new_socket
            return None

        new_socket = wait_until(
            moved,
            "channel child did not clear the old attachment and bind the new session",
            timeout=8,
        )
        ring(client, new_socket, "H21c second attachment")

        client.close_input()
        child.wait(timeout=8)
        assert child.returncode == 0
        wait_until(
            lambda: assert_registration_cleared(args.registration_2, new_socket),
            "channel shutdown did not clear the re-attached registration and socket",
        )
    finally:
        if child.poll() is None:
            child.terminate()
            child.wait(timeout=5)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bun", required=True)
    parser.add_argument("--server", required=True)
    parser.add_argument("--registration", required=True)
    parser.add_argument("--registration-2")
    parser.add_argument("--next-session-id")
    parser.add_argument("--late-session-id")
    parser.add_argument("--child-session-id")
    parser.add_argument("--child-project-dir")
    parser.add_argument("--child-sessions-dir")
    parser.add_argument("--client-channel-marker", action="store_true")
    parser.add_argument("--dangerously-load-development-channels")
    parser.add_argument("--inbox")
    parser.add_argument("--outbox")
    parser.add_argument("--channels-dir")
    parser.add_argument("--stderr", required=True)
    parser.add_argument("--scenario", choices=("full", "orphan", "reattach", "tools-only"), default="full")
    parser.add_argument("--cwd", default=None,
                        help="spawn the child with this cwd (Claude Code uses the plugin dir, not the project)")
    parser.add_argument("--registry-pid-file", required=True,
                        help="Claude registry entry for this client, the channel child's parent process")
    args = parser.parse_args()

    rewrite_registry(args.registry_pid_file, pid=os.getpid())
    with open(args.stderr, "w", encoding="utf-8") as stderr:
        if args.scenario == "orphan":
            assert args.channels_dir
            run_orphan(args, stderr)
        elif args.scenario == "reattach":
            run_reattach(args, stderr)
        elif args.scenario == "tools-only":
            assert args.inbox and args.outbox and args.channels_dir
            run_tools_only(args, stderr)
        else:
            assert args.inbox and args.outbox
            run_full(args, stderr)


if __name__ == "__main__":
    main()
