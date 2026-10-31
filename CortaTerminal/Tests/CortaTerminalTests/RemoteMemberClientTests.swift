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
import Testing
@testable import CortaTerminal

struct RemoteMemberClientTests {
    @Test func quietRemoteToolsNeverMasqueradeAsAnIdleAgent() throws {
        let encoded = Data(RemoteMemberClient.script.utf8).base64EncodedString()
        let code = """
        import base64,io,unittest.mock as mock
        ns={'__name__':'fixture','__file__':'/tmp/fixture/corta'}
        exec(base64.b64decode('\(encoded)'),ns)
        ns['settings']=lambda: {'tmux':'fixture'}
        busy=False
        def opened(path,*args,**kwargs):
            pid=int(path.split('/')[2])
            if path.endswith('/children'):
                return io.StringIO('2' if pid==1 else ('3' if pid==2 and busy else ''))
            if path.endswith('/io'): return io.StringIO('wchar: 0')
            fields=['S']+['0']*20
            fields[11]=fields[12]='1'
            name={1:'bash',2:'grok',3:'sleep'}[pid]
            return io.StringIO(str(pid)+' ('+name+') '+' '.join(fields))
        with mock.patch('builtins.open',side_effect=opened), mock.patch.object(
                ns['subprocess'],'check_output',return_value=b'grok|1'):
            assert ns['state']()==('grok',True,False)
            assert ns['state']()==('grok',True,False)
            assert ns['state']()==('grok',True,True)
            busy=True
            for _ in range(4): assert ns['state']()==('grok',True,False)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-B", "-c", code]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, Comment(rawValue: String(decoding: data, as: UTF8.self)))
    }

    @Test func wrapperActuallyInstallsAnExecutableClientAndValidPrivateConnectionFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("remote-client-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = root.appendingPathComponent("tmux")
        try "#!/bin/sh\nexit 1\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let tmux = RemoteTmux(id: UUID())
        let installed = URL(fileURLWithPath: "/tmp/" + tmux.sessionName)
        defer { try? FileManager.default.removeItem(at: installed) }
        var extras = RemoteTmux.Extras()
        extras.installRemoteClient = true
        extras.environmentName = "CORTA_MEMBER_TOKEN"
        extras.environmentValue = "0123456789abcdef0123456789abcdef"
        extras.reverseRemote = "/tmp/corta-test-remote.sock"
        extras.reverseLocal = "/tmp/corta-test-local.sock"
        var environment = ChildEnvironment.default()
        environment.merge(["PATH": root.path + ":/usr/bin:/bin", "SHELL": "/usr/bin/true"]) { _, new in new }
        let pty = try PTY.spawn(executable: "/bin/sh", arguments: ["-c", tmux.command(extras: extras)],
                                environment: environment)
        defer { pty.close() }
        _ = pty.readOutput(timeout: testTimeout(5))
        let client = installed.appendingPathComponent("corta")
        #expect(try Data(contentsOf: client) == Data(RemoteMemberClient.script.utf8))
        #expect(FileManager.default.isExecutableFile(atPath: client.path))
        let connection = installed.appendingPathComponent("connection.json")
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: connection)) as? [String: String])
        #expect(object == ["token": extras.environmentValue, "socket": extras.reverseRemote, "tmux": tmux.sessionName])
        let attributes = try FileManager.default.attributesOfItem(atPath: connection.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let help = try PTY.spawn(executable: client.path, arguments: ["--help"], environment: environment)
        defer { help.close() }
        #expect(help.readOutput(timeout: testTimeout(5)).contains("--reply-to"))
    }
}
