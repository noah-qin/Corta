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

"""Prepare isolated actual build/find workloads for corta-bench --real-producers."""
from pathlib import Path
root = Path("/tmp/corta-reader-producers")
source = root / "project" / "Sources" / "Workload"
source.mkdir(parents=True, exist_ok=True)
(root / "project" / "Package.swift").write_text(
    '// swift-tools-version: 6.0\nimport PackageDescription\n'
    'let package = Package(name: "Workload", products: [.library(name: "Workload", targets: ["Workload"])], '
    'targets: [.target(name: "Workload")])\n'
)
for index in range(20):
    (source / f"Unit{index}.swift").write_text(
        f"public func value{index}(_ n: Int) -> Int {{ (0..<n).reduce(0, +) }}\n"
    )
tree = root / "tree"
tree.mkdir(exist_ok=True)
for index in range(5000):
    (tree / f"file-{index:05}.txt").touch()
print(root)
