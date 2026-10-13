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

"""Compile production sources for CodeQL without rebuilding unrelated targets."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import time
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "CortaTerminal"
XCODE_TARGETS = {"CortaTerminal", "CortaSFTP", "corta-exec", "corta-image-decoder"}
NATIVE_SUFFIXES = {".c", ".cc", ".cpp", ".cxx", ".m", ".mm"}


def run(command):
    print("+ " + " ".join(map(str, command)), flush=True)
    start = time.monotonic()
    subprocess.run(list(map(str, command)), cwd=ROOT, check=True)
    print(f"Completed in {time.monotonic() - start:.1f}s", flush=True)


def build_app(derived_data):
    run(["xcodebuild", "clean", "build", "-project", "Corta.xcodeproj", "-scheme", "Corta",
         "-configuration", "Debug", "-destination", "generic/platform=macOS",
         "-derivedDataPath", derived_data, "-disableAutomaticPackageResolution",
         "-onlyUsePackageVersionsFromResolvedFile", "CODE_SIGNING_ALLOWED=NO",
         "CODE_SIGNING_REQUIRED=NO", "DEVELOPMENT_TEAM=", "EXCLUDED_SOURCE_FILE_NAMES=*.metal",
         "COMPILER_INDEX_STORE_ENABLE=NO", "COMPILATION_CACHE_ENABLE_CACHING=NO",
         "SWIFT_ENABLE_COMPILE_CACHE=NO", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES",
         "-showBuildTimingSummary"])


def native_sources():
    files = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode().split("\0")
    return sorted(path for path in files if Path(path).suffix in NATIVE_SUFFIXES)


def build_c(derived_data):
    sources = native_sources()
    if sources == ["Corta/SharedMemory.c"]:
        derived_data.mkdir(parents=True, exist_ok=True)
        run(["xcrun", "clang", "-c", "-std=gnu17", "-DDEBUG=1", "-arch", "arm64",
             "-mmacosx-version-min=26.0", "Corta/SharedMemory.c", "-o", derived_data / "SharedMemory.o"])
    elif sources:
        # A new native target/header setup may need project-specific compiler flags.
        print("Native source inventory changed; using the full Xcode extraction build.", flush=True)
        build_app(derived_data)
    else:
        print("No native sources to extract.", flush=True)


def supplemental_layout_supported(manifest, products):
    expected = XCODE_TARGETS | {"LicenseHeaders", "ReleaseCheck", "corta-license", "corta-release-check",
                                "corta-dump", "corta-bench", "corta-fuzz"}
    actual = {t["name"] for t in manifest["targets"] if t["type"] != "test"}
    return (actual == expected and not manifest.get("dependencies") and
            all((products / (name + ".swiftmodule")).exists() for name in ("CortaTerminal", "CortaSFTP")))


def build_swift_tools(derived_data):
    products = derived_data / "Build/Products/Debug"
    prepared_manifest = Path(os.environ.get("RUNNER_TEMP", str(derived_data))) / "codeql-package.json"
    manifest = (json.loads(prepared_manifest.read_text()) if prepared_manifest.is_file() else
                json.loads(subprocess.check_output(
                    ["swift", "package", "--disable-sandbox", "--package-path", str(PACKAGE), "dump-package"], cwd=ROOT)))
    scratch = derived_data / "supplemental"
    if not supplemental_layout_supported(manifest, products):
        print("Package layout changed; extracting all SwiftPM products.", flush=True)
        run(["swift", "build", "--package-path", PACKAGE, "--scratch-path", scratch,
             "--arch", "arm64", "--disable-build-manifest-caching"])
        return
    # SwiftPM builds these tools with their own settings and without the core.
    for product in ("corta-license", "corta-release-check"):
        run(["swift", "build", "--package-path", PACKAGE, "--scratch-path", scratch,
             "--product", product, "--arch", "arm64", "--disable-build-manifest-caching"])
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    version = next(p["version"] for p in manifest["platforms"] if p["platformName"] == "macos")
    for product in ("corta-dump", "corta-bench", "corta-fuzz"):
        target = next(t for t in manifest["targets"] if t["name"] == product)
        isolation = {"kind": {"defaultIsolation": {"_0": "nonisolated"}}, "tool": "swift"}
        if (any(target.get(k) for k in ("path", "sources", "exclude", "resources", "pluginUsages")) or
            any(s != isolation for s in target.get("settings", [])) or
            any(d.get("byName", [None])[0] not in XCODE_TARGETS for d in target.get("dependencies", []))):
            run(["swift", "build", "--package-path", PACKAGE, "--scratch-path", scratch,
                 "--product", product, "--arch", "arm64", "--disable-build-manifest-caching"])
            continue
        sources = sorted((PACKAGE / "Sources" / product).rglob("*.swift"))
        if not sources:
            raise RuntimeError(f"No sources for {product}")
        run(["xcrun", "swiftc", "-c", "-whole-module-optimization", "-Onone", "-swift-version", "6",
             "-D", "SWIFT_PACKAGE", "-D", "DEBUG", "-package-name", "cortaterminal",
             "-module-name", product.replace("-", "_"), "-target", f"arm64-apple-macosx{version}",
             "-sdk", sdk, "-I", products, "-F", products / "PackageFrameworks",
             "-o", scratch / (product + ".o"), *sources])


def verify_coverage(language, database):
    archive = database / "src.zip"
    if language == "swift":
        expected = [p.relative_to(ROOT).as_posix() for folder in (ROOT / "Corta", PACKAGE / "Sources")
                    for p in folder.rglob("*.swift")]
    else:
        expected = native_sources()
    with zipfile.ZipFile(archive) as source_archive:
        extracted = source_archive.namelist()
    missing = [path for path in expected if not any(name.endswith("/" + path) or name == path
                                                   for name in extracted)]
    if missing:
        raise RuntimeError("Production files missing from CodeQL source archive: " + ", ".join(missing))
    print(f"Verified {len(expected)} production {language} source files in CodeQL's archive.", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("app", "c", "swift-tools", "verify-swift", "verify-c"))
    parser.add_argument("--derived-data", type=Path, required=True)
    args = parser.parse_args()
    if args.mode.startswith("verify-"):
        verify_coverage("swift" if args.mode == "verify-swift" else "c-cpp", args.derived_data.resolve())
    else:
        {"app": build_app, "c": build_c, "swift-tools": build_swift_tools}[args.mode](args.derived_data.resolve())
