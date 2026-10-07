#!/usr/bin/env python3
# Copyright 2026 Noah Qin
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# SPDX-License-Identifier: Apache-2.0

import os
import pathlib
import pwd
import shutil
import socket
import subprocess
import tempfile
import time


def wait_for_listener(port, proc, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            return False
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=0.5):
                return True
        except OSError:
            time.sleep(0.05)
    return False


def run_fixture(root):
    proc = None
    log = None
    try:
        for name in ('host','client','wrong'):
         subprocess.run(['/usr/bin/ssh-keygen','-q','-t','ed25519','-N','','-f',str(root/name)],check=True)
        (root/'authorized_keys').write_text((root/'client.pub').read_text()); (root/'remote').mkdir()
        sock=socket.socket();sock.bind(('127.0.0.1',0));port=sock.getsockname()[1];sock.close()
        (root/'sshd.conf').write_text(f'''ListenAddress 127.0.0.1\nPort {port}\nHostKey {root}/host\nPidFile {root}/sshd.pid\nAuthorizedKeysFile {root}/authorized_keys\nStrictModes no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nUsePAM no\nAllowUsers {pwd.getpwuid(os.getuid()).pw_name}\nSubsystem sftp internal-sftp -d {root}/remote\n''')
        log = open(root / 'sshd.log', 'w')
        proc = subprocess.Popen(
            ['/usr/sbin/sshd', '-D', '-e', '-f', str(root / 'sshd.conf')], stdout=log, stderr=log)
        # Wait for the listener rather than a fixed pause: on a loaded runner
        # sshd can take longer to bind than any guess, and the tests would
        # then fail as connection refused.
        if not wait_for_listener(port, proc, timeout=10):
            log.flush()
            print((root / 'sshd.log').read_text())
            raise SystemExit(1)
        pub=(root/'host.pub').read_text().split();(root/'known_hosts').write_text(f'[127.0.0.1]:{port} {pub[0]} {pub[1]}\n')
        base=f'''Host fixture\n HostName 127.0.0.1\n Port {port}\n User {pwd.getpwuid(os.getuid()).pw_name}\n IdentityFile {root}/client\n IdentitiesOnly yes\n IdentityAgent none\n ForwardAgent no\n BatchMode yes\n StrictHostKeyChecking yes\n UserKnownHostsFile {root}/known_hosts\n GlobalKnownHostsFile /dev/null\n ConnectTimeout 3\n'''
        (root/'ssh.conf').write_text(base);(root/'auth-failure.conf').write_text(base.replace(f'{root}/client',f'{root}/wrong'))
        (root/'key-failure.conf').write_text(base.replace(f'{root}/known_hosts',f'{root}/wrong_known_hosts'))
        wrong=(root/'wrong.pub').read_text().split();(root/'wrong_known_hosts').write_text(f'[127.0.0.1]:{port} {wrong[0]} {wrong[1]}\n')
        env = dict(os.environ, CORTA_SSH_TEST_ROOT=str(root), SSH_AUTH_SOCK='', CORTA_TEST_TIMEOUT_SCALE='3')
        result = subprocess.run(['swift', 'test', '--package-path', 'CortaTerminal', '--filter', 'SFTPSSHIntegrationTests'], env=env)
        if result.returncode:
            log.flush()
            print((root / 'sshd.log').read_text())
        return result.returncode
    finally:
        if proc is not None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
        if log is not None:
            log.close()
        shutil.rmtree(root)


if __name__ == '__main__':
    fixture_root = pathlib.Path(tempfile.mkdtemp(prefix='corta-ssh-fixture-', dir='/private/tmp'))
    raise SystemExit(run_fixture(fixture_root))
