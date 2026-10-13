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

    def manifest(self):
        extras = ("LicenseHeaders", "ReleaseCheck", "corta-license", "corta-release-check",
                  "corta-dump", "corta-bench", "corta-fuzz")
        return {"targets": self.targets + [{"name": name, "type": "regular"} for name in extras]}

    def test_existing_layout_reuses_fresh_xcode_modules(self):
        self.assertTrue(extract.supplemental_layout_supported(self.manifest(), self.products))

    def test_new_target_external_package_or_missing_module_falls_back(self):
        manifest = self.manifest()
        manifest["targets"].append({"name": "NewTool", "type": "executable"})
        self.assertFalse(extract.supplemental_layout_supported(manifest, self.products))
        manifest = self.manifest()
        manifest["dependencies"] = [{"package": "external"}]
        self.assertFalse(extract.supplemental_layout_supported(manifest, self.products))
        (self.products / "CortaSFTP.swiftmodule").rmdir()
        self.assertFalse(extract.supplemental_layout_supported(self.manifest(), self.products))


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
