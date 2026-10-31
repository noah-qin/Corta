// Copyright 2026 Noah Qin
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The per-session Linux helper, explicitly installed when a user enables remote membership.
public enum RemoteMemberClient {
    public static let script = #"""
#!/usr/bin/env python3
"""The session-scoped Corta member transport; no transcript or credentials in argv."""
import argparse
import json
import os
import socket
import stat
import subprocess
import sys
import time

LIMIT = 65536
ROOT = os.path.dirname(os.path.realpath(__file__))
PREVIOUS = None
QUIET_SAMPLES = 0

def settings():
    fd = os.open(os.path.join(ROOT, 'connection.json'), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_size > 4096:
            raise ValueError('invalid connection file')
        return json.loads(os.read(fd, 4096))
    finally:
        os.close(fd)

def exchange(request):
    config = settings()
    request = dict(request, token=config['token'], tmux=config['tmux'])
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(15)
        sock.connect(config['socket'])
        sock.sendall(json.dumps(request, ensure_ascii=True).encode() + b'\n')
        data = bytearray()
        while b'\n' not in data:
            chunk = sock.recv(4096)
            if not chunk or len(data) + len(chunk) > LIMIT * 32:
                raise ValueError('invalid reply')
            data.extend(chunk)
        return json.loads(bytes(data).split(b'\n', 1)[0])

def wait(request, seconds):
    deadline = time.monotonic() + min(max(seconds, 1), 110)
    while time.monotonic() < deadline:
        reply = exchange(dict(request, op='read'))
        if not reply['ok'] or reply['text']:
            return reply
        time.sleep(0.1)
    return exchange(dict(request, op='wait'))

def state():
    global PREVIOUS, QUIET_SAMPLES
    config = settings()
    target = '=' + config['tmux'] + ':0.0'
    line = subprocess.check_output(['tmux', 'display-message', '-p', '-t', target,
                                    '#{pane_current_command}|#{pane_pid}'], timeout=2).decode().strip()
    name, pid = line.split('|', 1)
    supported = name.lower() in ('claude', 'claude-code', 'codex', 'kimi', 'grok', 'gemini', 'aider', 'opencode')
    pids = [int(pid)]
    cpu = 0
    writes = 0
    tool_active = False
    for process in pids:
        if len(pids) > 256:
            return name.lower(), False, False
        try:
            with open('/proc/%d/task/%d/children' % (process, process)) as children:
                pids.extend(int(child) for child in children.read(4096).split())
            with open('/proc/%d/stat' % process) as info:
                raw = info.read(4096)
                fields = raw.rsplit(')', 1)[1].split()
                comm = raw.split('(', 1)[1].rsplit(')', 1)[0].lower()
                interpreters = ('node', 'bun', 'python', 'python3', 'deno')
                if process != int(pid) and comm not in (name.lower(),) + interpreters:
                    tool_active = True
                cpu += int(fields[11]) + int(fields[12])
            with open('/proc/%d/io' % process) as info:
                values = dict(line.split(':', 1) for line in info.read(4096).splitlines())
                writes += int(values.get('wchar', 0))
        except (OSError, ValueError, IndexError):
            return name.lower(), supported, False
    current = (tuple(pids), cpu, writes)
    QUIET_SAMPLES = QUIET_SAMPLES + 1 if PREVIOUS == current else 0
    idle = QUIET_SAMPLES >= 2 and not tool_active
    PREVIOUS = current
    return name.lower(), supported, idle

def monitor():
    # This helper exists only while this SSH wrapper is attached. It sends
    # process metadata, never screen text. OSC status provides the idle signal.
    while True:
        try:
            name, foreground, idle = state()
            exchange({'op': 'state', 'body': json.dumps({'kind': name, 'foreground': foreground, 'idle': idle})})
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
        time.sleep(1)

def mcp():
    names = ['members', 'whoami', 'send', 'read', 'wait', 'status']
    while True:
        line = sys.stdin.buffer.readline(LIMIT * 6 + 8193)
        if not line:
            break
        if len(line) > LIMIT * 6 + 8192:
            return 1
        obj = json.loads(line)
        if 'id' not in obj:
            continue
        method = obj.get('method')
        result = {}
        if method == 'initialize':
            result = {'protocolVersion': obj.get('params', {}).get('protocolVersion', '2024-11-05'),
                      'capabilities': {'tools': {}}, 'serverInfo': {'name': 'corta', 'version': '1'}}
        elif method == 'tools/list':
            tools = []
            for name in names:
                properties = {}
                required = []
                if name == 'send':
                    properties = {'to': {'type': 'string'}, 'body': {'type': 'string'},
                                  'reply_to': {'type': 'integer'}, 'context': {'type': 'boolean'}}
                    required = ['to', 'body']
                elif name == 'status':
                    properties = {'message_id': {'type': 'integer'}}
                    required = ['message_id']
                elif name == 'wait':
                    properties = {'timeout': {'type': 'integer', 'minimum': 1, 'maximum': 55}}
                elif name == 'read':
                    properties = {'since': {'type': 'integer'}}
                tools.append({'name': 'corta_' + name, 'description': 'Corta member ' + name,
                              'inputSchema': {'type': 'object', 'properties': properties,
                                              'required': required, 'additionalProperties': False}})
            result = {'tools': tools}
        elif method == 'tools/call':
            params = obj.get('params', {})
            name = params.get('name', '')[len('corta_'):]
            args = params.get('arguments', {})
            request = dict(args, op=name)
            if 'message_id' in request:
                request['number'] = request.pop('message_id')
            if 'reply_to' in request:
                request['replyTo'] = request.pop('reply_to')
            reply = wait(request, min(args.get('timeout', 55), 55)) if name == 'wait' else exchange(request)
            result = {'isError': not reply['ok'], 'content': [{'type': 'text', 'text': reply['text']}]}
        print(json.dumps({'jsonrpc': '2.0', 'id': obj['id'], 'result': result}), flush=True)
    return 0

def main():
    parser = argparse.ArgumentParser(prog='corta')
    parser.add_argument('op', choices=['members', 'whoami', 'send', 'read', 'wait', 'status', 'mcp', 'monitor'])
    parser.add_argument('arguments', nargs='*')
    parser.add_argument('--json', action='store_true')
    parser.add_argument('--context', action='store_true')
    parser.add_argument('--reply-to', type=int)
    parser.add_argument('--timeout', type=int, default=110)
    parser.add_argument('--since', type=int)
    args = parser.parse_intermixed_args()
    if args.op == 'mcp':
        return mcp()
    if args.op == 'monitor':
        return monitor()
    request = {'op': args.op, 'context': args.context, 'replyTo': args.reply_to, 'since': args.since}
    if args.op == 'send':
        if len(args.arguments) < 2:
            parser.error('send requires a member ID and a body')
        body = ' '.join(args.arguments[1:])
        if body == '-':
            body = sys.stdin.buffer.read(LIMIT + 1).decode()
        if len(body.encode()) > LIMIT:
            parser.error('body exceeds 64 KiB')
        request.update(to=args.arguments[0], body=body)
    if args.op == 'status':
        request['number'] = int(args.arguments[0])
    reply = wait(request, args.timeout) if args.op == 'wait' else exchange(request)
    print(json.dumps(reply) if args.json else reply['text'])
    return 0 if reply['ok'] else 1

if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as exc:
        print('refused(unavailable): ' + str(exc), file=sys.stderr)
        sys.exit(1)
"""#
}
