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

"""Prevent extraction optimizations from omitting new production targets."""

import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location("extract", Path(__file__).resolve().parents[1] / "codeql-extract.py")
extract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(extract)


class SupplementalTargetsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.products = Path(self.temp.name)
        for name in ("CortaTerminal", "CortaSFTP"):
            (self.products / (name + ".swiftmodule")).mkdir()
        self.targets = [{"name": name, "type": "regular", "dependencies": []}
                        for name in sorted(extract.XCODE_TARGETS)]

    def plan(self, extra, **fields):
        return extract.supplemental_targets({"targets": self.targets + extra, **fields}, self.products)

    def test_only_missing_targets_and_dependency_order(self):
        executable = {"name": "tool", "type": "executable", "dependencies": [{"byName": ["Library", None]}]}
        library = {"name": "Library", "type": "regular", "dependencies": []}
        test = {"name": "LibraryTests", "type": "test", "dependencies": []}
        self.assertEqual([t["name"] for t in self.plan([executable, library, test])], ["Library", "tool"])

    def test_new_target_is_included(self):
        self.assertEqual([t["name"] for t in self.plan([
            {"name": "NewTool", "type": "executable", "dependencies": [{"byName": ["CortaTerminal", None]}]}
        ])], ["NewTool"])

    def test_unknown_settings_resources_or_external_dependencies_fall_back(self):
        for fields in ({"settings": [{"tool": "swift", "kind": {"define": {"_0": "CUSTOM"}}}]},
                       {"resources": ["asset"]}, {"path": "custom"}, {"exclude": ["file.swift"]},
                       {"dependencies": [{"product": ["External", "package", None, None]}]}):
            target = {"name": "Tool", "type": "executable", "dependencies": [], **fields}
            self.assertIsNone(self.plan([target]), fields)
        self.assertIsNone(self.plan([], dependencies=[{"package": "external"}]))

    def test_missing_xcode_module_falls_back(self):
        (self.products / "CortaSFTP.swiftmodule").rmdir()
        self.assertIsNone(self.plan([]))

    def test_dependency_cycle_falls_back(self):
        self.assertIsNone(self.plan([
            {"name": "A", "type": "regular", "dependencies": [{"byName": ["B", None]}]},
            {"name": "B", "type": "regular", "dependencies": [{"byName": ["A", None]}]},
        ]))


class CoverageTests(unittest.TestCase):
    def test_missing_native_file_fails_coverage(self):
        with tempfile.TemporaryDirectory() as directory:
            database = Path(directory)
            with zipfile.ZipFile(database / "src.zip", "w") as archive:
                archive.writestr("repo/Corta/SharedMemory.c", "source")
            with patch.object(extract, "native_sources", return_value=["Corta/SharedMemory.c"]):
                extract.verify_coverage("c-cpp", database)
            with patch.object(extract, "native_sources", return_value=["Corta/New.c"]):
                with self.assertRaisesRegex(RuntimeError, "Corta/New.c"):
                    extract.verify_coverage("c-cpp", database)


if __name__ == "__main__":
    unittest.main()
