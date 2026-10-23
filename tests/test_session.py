"""Real local socket/protocol tests, with an explicit backend that cannot post HID input."""
import concurrent.futures
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from hidctl import request

BIN = ROOT / 'build' / 'hid-session'
APP = 'com.apple.TextEdit'


class Running:
    def __init__(self, idle=20, lifetime=30, limit=100):
        self.temp = tempfile.TemporaryDirectory(prefix='hid-test-', dir='/private/tmp')
        self.path = Path(self.temp.name) / 'control.sock'
        self.proc = subprocess.Popen([str(BIN), '--simulate', '--socket', str(self.path), '--uid', str(os.getuid()),
            '--lifetime', str(lifetime), '--idle', str(idle), '--max-actions', str(limit), '--protocol', '1'],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        end = time.monotonic() + 3
        while not self.path.exists() and self.proc.poll() is None and time.monotonic() < end:
            time.sleep(.01)
        if not self.path.exists():
            raise AssertionError(self.proc.communicate())
        self.counter = 0

    def call(self, **kwargs):
        self.counter += 1
        payload = {'id': 'test-' + str(self.counter), **kwargs}
        return request(self.path, payload, simulated=True)

    def close(self):
        if self.proc.poll() is None:
            try:
                self.call(op='stop')
            except OSError:
                self.proc.terminate()
        self.proc.communicate(timeout=4)
        self.temp.cleanup()


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.s = Running()

    def tearDown(self):
        self.s.close()

    def batch(self, actions, **extra):
        return self.s.call(op='batch', app=APP, actions=actions, **extra)

    def status(self):
        return self.s.call(op='status')

    def test_multiple_requests_reuse_devices(self):
        first = self.status()
        for key in ['tab', 'cmd+f', 'escape', 'test-x']:
            self.assertTrue(self.batch([{'type': 'key', 'key': key}])['ok'])
        last = self.status()
        self.assertEqual(first['pid'], last['pid'])
        self.assertEqual(last['device_initializations'], 1)
        self.assertEqual(last['reports'], 8)

    def test_invalid_tail_does_not_execute_valid_prefix(self):
        result = self.batch([{'type': 'key', 'key': 'tab'}, {'type': 'shell', 'key': 'rm'}])
        self.assertFalse(result['ok'])
        self.assertEqual(self.status()['reports'], 0)

    def test_outside_coordinate_prevents_entire_batch(self):
        result = self.batch([{'type': 'key', 'key': 'tab'}, {'type': 'click', 'x': 9999, 'y': 50}])
        self.assertFalse(result['ok'])
        self.assertEqual(self.status()['reports'], 0)

    def test_frontmost_mismatch_posts_zero(self):
        result = self.s.call(op='batch', app='com.tencent.xinWeChat', actions=[{'type': 'key', 'key': 'cmd+f'}])
        self.assertEqual(result['error'], 'foreground_mismatch')
        self.assertFalse(result['partial_input_possible'])
        self.assertEqual(self.status()['reports'], 0)

    def test_activation_is_explicit_and_first(self):
        result = self.s.call(op='batch', app='com.tencent.xinWeChat', actions=[{'type': 'activate'}, {'type': 'key', 'key': 'cmd+f'}])
        self.assertTrue(result['ok'])
        self.assertEqual(self.status()['front_app'], 'com.tencent.xinWeChat')
        result = self.batch([{'type': 'key', 'key': 'tab'}, {'type': 'activate'}])
        self.assertFalse(result['ok'])

    def test_test_character_never_allowed_in_wechat(self):
        result = self.s.call(op='batch', app='com.tencent.xinWeChat', actions=[{'type': 'activate'}, {'type': 'key', 'key': 'test-x'}])
        self.assertFalse(result['ok'])
        self.assertEqual(self.status()['reports'], 0)

    def test_duplicate_id_returns_result_not_input(self):
        action = [{'type': 'key', 'key': 'tab'}]
        first = self.batch(action, id='repeat')
        second = self.batch(action, id='repeat')
        self.assertTrue(first['ok'])
        self.assertTrue(second['replayed_result'])
        self.assertEqual(self.status()['reports'], 2)
        query = self.s.call(op='result', request_id='repeat')
        self.assertEqual(query['result'], first)
        conflict = self.batch([{'type': 'key', 'key': 'escape'}], id='repeat')
        self.assertFalse(conflict['ok'])
        self.assertEqual(self.status()['reports'], 2)

    def test_concurrent_duplicate_requests_post_once(self):
        payload = {'id': 'concurrent', 'op': 'batch', 'app': APP, 'actions': [{'type': 'key', 'key': 'tab'}]}
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: request(self.s.path, payload, simulated=True), range(2)))
        self.assertTrue(all(x['ok'] for x in results))
        self.assertEqual(sum(x.get('replayed_result', False) for x in results), 1)
        self.assertEqual(self.status()['reports'], 2)

    def test_wrong_server_identity_stops_client_before_send(self):
        with self.assertRaisesRegex(RuntimeError, 'identity'):
            request(self.s.path, {'id': 'bad-peer', 'op': 'batch', 'app': APP, 'actions': [{'type': 'key', 'key': 'tab'}]})
        self.assertEqual(self.status()['reports'], 0)

    def test_socket_permissions(self):
        self.assertEqual(self.s.path.stat().st_mode & 0o777, 0o600)

    def test_batch_and_key_limits(self):
        for actions in [[], [{'type': 'key', 'key': 'tab'}] * 17,
                        [{'type': 'key', 'key': 'cmd+q'}],
                        [{'type': 'key', 'key': 'tab', 'settle_ms': 99999}]]:
            self.assertFalse(self.batch(actions)['ok'])
        self.assertEqual(self.status()['reports'], 0)

    def test_large_integers_cannot_wrap_into_valid_delays(self):
        for action in [{'type': 'key', 'key': 'tab', 'settle_ms': 2**32 + 100},
                       {'type': 'scroll', 'x': 500, 'y': 400, 'delta': 2**32 + 1}]:
            self.assertFalse(self.batch([action])['ok'])
        self.assertEqual(self.status()['reports'], 0)

    def test_unknown_fields_and_bad_ids(self):
        for invalid in [self.batch([{'type': 'key', 'key': 'tab'}], id='../file'),
                        self.s.call(op='status', command='whoami'),
                        self.s.call(op='batch', app='com.apple.Terminal', actions=[{'type': 'activate'}])]:
            self.assertFalse(invalid['ok'])
        self.assertEqual(self.status()['reports'], 0)

    def test_move_then_click(self):
        result = self.batch([{'type': 'move', 'x': 550, 'y': 450}, {'type': 'click', 'x': 550, 'y': 450}])
        self.assertTrue(result['ok'])
        self.assertEqual(result['completed'], 2)
        cursor = self.status()['cursor']
        self.assertLessEqual(abs(cursor[0] - 550), 3)

    def test_oversized_and_malformed_request_do_not_kill_session(self):
        for data in [b'x' * 16385 + b'\n', b'{broken}\n', b'[]\n']:
            with socket.socket(socket.AF_UNIX) as client:
                client.connect(str(self.s.path))
                client.sendall(data)
                response = json.loads(client.recv(4096))
                self.assertFalse(response['ok'])
        self.assertEqual(self.status()['reports'], 0)


class LifecycleTests(unittest.TestCase):
    def test_status_does_not_extend_idle(self):
        s = Running(idle=1, lifetime=3)
        try:
            end = time.monotonic() + 2
            while s.proc.poll() is None and time.monotonic() < end:
                try:
                    s.call(op='status')
                except OSError:
                    break
                time.sleep(.1)
            s.proc.wait(timeout=2)
            self.assertFalse(s.path.exists())
        finally:
            s.close()

    def test_budget_checked_before_batch(self):
        s = Running(limit=1)
        try:
            result = s.call(op='batch', app=APP, actions=[{'type': 'key', 'key': 'tab'}] * 2)
            self.assertFalse(result['ok'])
            self.assertEqual(s.call(op='status')['reports'], 0)
            self.assertTrue(s.call(op='batch', app=APP, actions=[{'type': 'key', 'key': 'tab'}])['ok'])
            s.proc.wait(timeout=2)
            self.assertFalse(s.path.exists())
        finally:
            s.close()

    def test_existing_socket_path_not_overwritten(self):
        with tempfile.TemporaryDirectory(prefix='hid-test-', dir='/private/tmp') as folder:
            path = Path(folder) / 'control.sock'
            path.write_text('keep')
            run = subprocess.run([str(BIN), '--simulate', '--socket', str(path), '--uid', str(os.getuid()),
                '--lifetime', '3', '--idle', '1', '--max-actions', '10', '--protocol', '1'], capture_output=True)
            self.assertNotEqual(run.returncode, 0)
            self.assertEqual(path.read_text(), 'keep')

    def test_default_cli_validation_never_starts_service(self):
        q = {'app': APP, 'actions': [{'type': 'key', 'key': 'test-x'}]}
        run = subprocess.run([sys.executable, str(ROOT / 'hidctl.py'), 'batch', '-'], input=json.dumps(q), text=True, capture_output=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertFalse(json.loads(run.stdout)['input_posted'])


if __name__ == '__main__':
    unittest.main()
