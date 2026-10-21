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

import Darwin

/// Makes an open file owner-only: no extended ACL, mode `0600`.
///
/// `open(…, 0o600)` sets the mode bits and nothing else. An entry the
/// folder marks `file_inherit` is copied onto the new file regardless, keeps
/// granting another account read access through a rename and a later
/// `chmod`, and `ls -l` shows only a `+`. Both the app's private files and
/// the SFTP client's downloads pass through here.
///
/// - Returns: 0, or the `errno` of the step that failed.
public func makeOwnerOnly(descriptor: Int32) -> Int32 {
    let cleared = clearExtendedACL { acl_set_fd_np(descriptor, $0, ACL_TYPE_EXTENDED) }
    guard cleared == 0 else { return cleared }
    return fchmod(descriptor, 0o600) == 0 ? 0 : errno
}

/// Removes every extended ACL entry from the file or folder at `path`.
///
/// - Returns: 0, or the `errno` of the failure.
public func clearExtendedACL(path: String) -> Int32 {
    clearExtendedACL { acl_set_file(path, ACL_TYPE_EXTENDED, $0) }
}

/// A volume without ACLs (exFAT, FAT, some SMB shares) answers ENOTSUP: it
/// has none to inherit, so that counts as cleared — refusing it would make
/// every write to a USB stick fail.
private func clearExtendedACL(_ apply: (acl_t) -> Int32) -> Int32 {
    guard let empty = acl_init(0) else { return errno }
    defer { acl_free(UnsafeMutableRawPointer(empty)) }
    guard apply(empty) != 0 else { return 0 }
    let code = errno
    return code == ENOTSUP || code == EOPNOTSUPP ? 0 : code
}
