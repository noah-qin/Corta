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

"""The feed's header comment is corrected only where a path went stale."""

import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("header", Path(__file__).resolve().parents[1] / "appcast-header.py")
header = importlib.util.module_from_spec(spec)
spec.loader.exec_module(header)

FEED = """<?xml version="1.0"?>
<!--
  Checked from `Corta/UpdateController.swift`, keyed by `Sparkle-Info.plist`.
-->
<rss><item><description>`Corta/UpdateController.swift`</description></item></rss>
<!-- sparkle-signatures:
edSignature: abc
-->
"""


class HeaderTests(unittest.TestCase):
    def tree(self, *files):
        root = Path(tempfile.mkdtemp())
        for name in files:
            (root / name).parent.mkdir(parents=True, exist_ok=True)
            (root / name).write_text("")
        return root

    def test_moved_file_is_repointed_in_the_header_only(self):
        root = self.tree("Corta/App/UpdateController.swift", "Sparkle-Info.plist")
        text, changes = header.refresh(FEED, root)
        self.assertEqual(changes, [("Corta/UpdateController.swift", "Corta/App/UpdateController.swift")])
        self.assertIn("from `Corta/App/UpdateController.swift`", text)
        self.assertIn("<description>`Corta/UpdateController.swift`</description>", text)
        self.assertTrue(text.endswith(FEED[FEED.index("<rss"):]))

    def test_current_paths_leave_the_feed_byte_for_byte(self):
        root = self.tree("Corta/UpdateController.swift", "Sparkle-Info.plist")
        self.assertEqual(header.refresh(FEED, root), (FEED, []))

    def test_a_missing_or_ambiguous_file_fails(self):
        for files in (("Sparkle-Info.plist",),
                      ("Sparkle-Info.plist", "Corta/A/UpdateController.swift", "Corta/B/UpdateController.swift")):
            with self.assertRaises(ValueError):
                header.refresh(FEED, self.tree(*files))


if __name__ == "__main__":
    unittest.main()
