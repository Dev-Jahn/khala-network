#!/usr/bin/env python3
"""Drive the khala channel MCP child over stdio for H21."""

import argparse
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


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bun", required=True)
    parser.add_argument("--server", required=True)
    parser.add_argument("--registration", required=True)
    parser.add_argument("--inbox", required=True)
    parser.add_argument("--outbox", required=True)
    parser.add_argument("--stderr", required=True)
    parser.add_argument("--cwd", default=None,
                        help="spawn the child with this cwd (Claude Code uses the plugin dir, not the project)")
    parser.add_argument("--registry-pid-file", default=None,
                        help="write this client's pid into the Claude registry entry at this path, so the "
                             "child (whose parent is this client) resolves session id and project cwd via "
                             "khala-link runtime session, exactly as under Claude Code")
    args = parser.parse_args()

    if args.registry_pid_file:
        entry = json.load(open(args.registry_pid_file, encoding="utf-8"))
        entry["pid"] = os.getpid()
        with open(args.registry_pid_file, "w", encoding="utf-8") as handle:
            json.dump(entry, handle)

    with open(args.stderr, "w", encoding="utf-8") as stderr:
        child = subprocess.Popen(
            [args.bun, args.server],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=stderr,
            text=True,
            bufsize=1,
            env=os.environ.copy(),
            cwd=args.cwd,
        )

        assert child.stdin is not None
        assert child.stdout is not None

        def send(message: dict) -> None:
            child.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
            child.stdin.flush()

        def receive(timeout: float = 5.0) -> dict:
            ready, _, _ = select.select([child.stdout], [], [], timeout)
            if not ready:
                raise AssertionError("timed out waiting for MCP output")
            line = child.stdout.readline()
            if not line:
                raise AssertionError(f"channel child exited early with {child.poll()}")
            return json.loads(line)

        def response(request_id: int) -> dict:
            while True:
                message = receive()
                if message.get("id") == request_id:
                    return message

        send(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {},
                    "clientInfo": {"name": "khala-h21", "version": "1"},
                },
            }
        )
        initialized = response(1)
        assert initialized["result"]["serverInfo"]["name"] == "khala", initialized
        assert "claude/channel" in initialized["result"]["capabilities"]["experimental"]
        send({"jsonrpc": "2.0", "method": "notifications/initialized"})

        send({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        listed = response(2)
        assert {tool["name"] for tool in listed["result"]["tools"]} == {
            "khala_drain",
            "khala_reply",
        }, listed

        send(
            {
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/call",
                "params": {"name": "khala_drain", "arguments": {}},
            }
        )
        drained = response(3)
        assert not drained["result"].get("isError", False), drained
        assert "body from H21 inbox" in drained["result"]["content"][0]["text"]
        assert not os.path.exists(os.path.join(args.inbox, "new", "1700000000.1.8.sender@alpha"))
        assert os.path.exists(os.path.join(args.inbox, "cur", "1700000000.1.8.sender@alpha"))

        def registered_socket():
            try:
                with open(args.registration, encoding="utf-8") as registration_file:
                    registration = json.load(registration_file)
            except (FileNotFoundError, json.JSONDecodeError):
                return None
            channel_socket = registration.get("channelSocket")
            channel_pid = registration.get("channelPID")
            channel_start = registration.get("channelPIDStart")
            if channel_socket and channel_pid == child.pid and channel_start and os.path.exists(channel_socket):
                return channel_socket
            return None

        channel_socket = wait_until(
            registered_socket,
            "channel child did not register and bind its socket",
        )
        assert os.path.basename(channel_socket).endswith(".sock")

        request = {
            "v": 1,
            "content": "KHALA-CONDUIT/1\npending: 1\ngeneration: h21-generation",
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

        notification = receive()
        assert notification["method"] == "notifications/claude/channel", notification
        params = notification["params"]
        assert params["content"] == request["content"]
        assert params["meta"]["from"] == "reel@bw2"
        assert params["meta"]["generation"] == "h21-generation"
        assert "unsafe-key" not in params["meta"]
        assert all(character not in params["meta"]["unsafe_value"] for character in '<>"\n')

        reply_to = "1700000000.1.9.sender@alpha"
        send(
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
        tool_reply = response(4)
        assert not tool_reply["result"].get("isError", False), tool_reply
        letter_id = tool_reply["result"]["content"][0]["text"].strip()
        letter_path = os.path.join(args.outbox, letter_id)
        wait_until(lambda: os.path.isfile(letter_path), "khala_reply wrote no outbox letter")
        with open(letter_path, encoding="utf-8") as letter_file:
            letter = letter_file.read()
        assert f"In-Reply-To: {reply_to}\n" in letter
        assert "Subject: Re: H21\n" in letter
        assert letter.endswith("\nreply from H21\n")

        child.stdin.close()
        child.wait(timeout=5)
        assert child.returncode == 0

        def cleared():
            with open(args.registration, encoding="utf-8") as registration_file:
                registration = json.load(registration_file)
            return (
                not registration.get("channelSocket")
                and not registration.get("channelPID")
                and not registration.get("channelPIDStart")
                and not os.path.exists(channel_socket)
            )

        wait_until(cleared, "channel shutdown did not clear registration and socket")


if __name__ == "__main__":
    main()
