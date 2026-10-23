#!/usr/bin/env python3
"""Normal-user client. One native admin approval starts a bounded native session."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import socket
import stat
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parent
STATE = Path.home() / '.local' / 'state' / 'mac-hid-session'


def private_state():
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = STATE.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise RuntimeError('State directory must belong to you and have mode 0700')
    return STATE


def atomic_json(path, value):
    temp = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as f:
        json.dump(value, f, ensure_ascii=False, indent=2)
        f.write('\n')
    temp.replace(path)


def request(path, payload, *, simulated=False, timeout=40):
    wire = json.dumps(payload, allow_nan=False, separators=(',', ':')).encode() + b'\n'
    if len(wire) > 16384:
        raise ValueError('Request exceeds 16 KiB')
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(timeout)
        client.connect(str(path))
        # macOS LOCAL_PEERCRED (SOL_LOCAL=0, LOCAL_PEERCRED=1): xucred version, uid.
        import struct
        credential = client.getsockopt(0, 1, 80)
        version, uid = struct.unpack_from('=II', credential)
        expected_uid = os.getuid() if simulated else 0
        if version != 0 or uid != expected_uid:
            raise RuntimeError('Server identity mismatch')
        client.sendall(wire)
        data = bytearray()
        while not data.endswith(b'\n'):
            chunk = client.recv(8192)
            if not chunk:
                raise RuntimeError('Connection closed; outcome unknown. Query the same request ID, do not repeat input.')
            data.extend(chunk)
            if len(data) > 131072:
                raise RuntimeError('Response too large')
        return json.loads(data)


def current():
    info = json.loads((private_state() / 'current.json').read_text())
    if not isinstance(info.get('socket'), str):
        raise RuntimeError('Invalid current session')
    return info


def start(args):
    state = private_state()
    if (state / 'current.json').exists():
        previous = current()
        try:
            live = request(previous['socket'], {'id': uuid.uuid4().hex, 'op': 'status'})
        except (OSError, RuntimeError):
            live = None
        if live and live.get('ok'):
            print(json.dumps({'reused': True, **live}, ensure_ascii=False))
            return
    binary = (ROOT / 'build' / 'hid-session').resolve(strict=True)
    checksum = hashlib.sha256(binary.read_bytes()).hexdigest()
    lifetime, idle = args.minutes * 60, args.idle_minutes * 60
    if not 60 <= lifetime <= 7200 or not 60 <= idle <= min(1800, lifetime):
        raise ValueError('Use 1–120 session minutes and 1–30 idle minutes, idle <= session')
    uid = os.getuid()
    if uid < 500:
        raise RuntimeError('Run hidctl as the desktop user, not root')
    # Root owns the runtime directory and its code. No persistent install, launchd or sudoers change.
    lines = [
        'set -eu',
        'stage=$(/usr/bin/mktemp -d /private/tmp/mac-hid-session.XXXXXXXX)',
        'trap \'/bin/rm -f "$stage/hid-session" "$stage/events.log"; /bin/rmdir "$stage" 2>/dev/null || true\' EXIT',
        '/usr/bin/install -m 0700 ' + shlex.quote(str(binary)) + ' "$stage/hid-session"',
        'actual=$(/usr/bin/shasum -a 256 "$stage/hid-session")',
        '[ "${actual%% *}" = ' + shlex.quote(checksum) + ' ]',
        '/bin/chmod 0711 "$stage"',
        '(umask 022; : > "$stage/events.log")',
        '/bin/launchctl asuser ' + str(uid) + ' "$stage/hid-session" --serve --socket "$stage/control.sock" --uid ' + str(uid) +
        ' --lifetime ' + str(lifetime) + ' --idle ' + str(idle) + ' --max-actions 500 --protocol 1 </dev/null >"$stage/events.log" 2>&1 &',
        'trap - EXIT',
        'printf "%s\\n" "$stage"',
    ]
    command = '\n'.join(lines)
    script = 'with timeout of 300 seconds\ndo shell script ' + json.dumps(command) + ' with administrator privileges\nend timeout'
    print('Approve the macOS administrator prompt once. No password is read by this program.', flush=True)
    result = subprocess.run(['/usr/bin/osascript', '-e', script], text=True, capture_output=True, timeout=310)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or 'Administrator startup failed')
    stage = Path(result.stdout.strip())
    if not str(stage).startswith('/private/tmp/mac-hid-session.') or '/' in stage.name:
        raise RuntimeError('Unexpected runtime directory')
    until = time.monotonic() + 25
    info = {'socket': str(stage / 'control.sock'), 'started_at': time.time(), 'binary_sha256': checksum}
    while time.monotonic() < until:
        try:
            status = request(info['socket'], {'id': uuid.uuid4().hex, 'op': 'status'})
            if status.get('ok'):
                info['pid'] = status['pid']
                atomic_json(state / 'current.json', info)
                print(json.dumps({'reused': False, **status}, ensure_ascii=False))
                return
        except (OSError, RuntimeError):
            pass
        if not stage.exists():
            break
        time.sleep(.1)
    # The privileged process has its own finite lifecycle, including startup failure cleanup.
    log = stage / 'events.log'
    message = log.read_text()[-2000:] if log.exists() else 'Native session did not become ready; inspect the driver status.'
    raise RuntimeError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('start', help='reuse a live session, otherwise request one admin approval')
    p.add_argument('--minutes', type=int, default=120)
    p.add_argument('--idle-minutes', type=int, default=30)
    sub.add_parser('status')
    sub.add_parser('stop')
    p = sub.add_parser('result')
    p.add_argument('id')
    p = sub.add_parser('batch', help='JSON request file, or - for stdin; default only validates')
    p.add_argument('file')
    p.add_argument('--execute', action='store_true')
    args = parser.parse_args()
    if args.command == 'start':
        start(args)
        return 0
    if args.command == 'batch':
        raw = sys.stdin.read(16385) if args.file == '-' else Path(args.file).read_text()
        payload = json.loads(raw)
        payload.setdefault('id', uuid.uuid4().hex)
        payload.setdefault('op', 'batch')
        encoded = json.dumps(payload, allow_nan=False)
        validation = subprocess.run([str(ROOT / 'build' / 'hid-session'), '--validate'], input=encoded, text=True, capture_output=True)
        if validation.returncode:
            raise ValueError(validation.stderr.strip())
        if not args.execute:
            print(json.dumps({'validated': True, 'input_posted': False, 'id': payload['id']}))
            return 0
    else:
        payload = {'id': uuid.uuid4().hex, 'op': args.command}
        if args.command == 'result':
            payload['request_id'] = args.id
    info = current()
    state = private_state()
    if args.command == 'batch':
        # Persist ID before connecting. Never automatically repeat an uncertain action.
        atomic_json(state / 'last-request.json', {'id': payload['id'], 'session_pid': info['pid'], 'at': time.time()})
    response = request(info['socket'], payload)
    if args.command == 'batch':
        atomic_json(state / ('result-' + payload['id'] + '.json'), response)
    print(json.dumps(response, ensure_ascii=False, indent=2))
    return 0 if response.get('ok') else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, RuntimeError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
