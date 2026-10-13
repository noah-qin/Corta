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
from pathlib import Path
import re
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


def supplemental_targets(manifest, products):
    if manifest.get("dependencies"):
        return None
    targets = {t["name"]: t for t in manifest["targets"] if t["type"] != "test"}
    if not XCODE_TARGETS.issubset(targets):
        return None
    for module in ("CortaTerminal", "CortaSFTP"):
        if not (products / (module + ".swiftmodule")).exists():
            return None
    ordered = []
    built = set(XCODE_TARGETS)
    pending = [t for name, t in targets.items() if name not in built]
    isolation = {"kind": {"defaultIsolation": {"_0": "nonisolated"}}, "tool": "swift"}
    while pending:
        progress = False
        for target in pending[:]:
            if (target["type"] not in ("regular", "executable") or
                any(target.get(key) for key in ("path", "sources", "exclude", "resources", "pluginUsages")) or
                any(setting != isolation for setting in target.get("settings", []))):
                return None
            dependencies = []
            for dependency in target.get("dependencies", []):
                name = dependency.get("byName", [None, None])
                if len(name) != 2 or name[0] not in targets or name[1] is not None:
                    return None
                dependencies.append(name[0])
            if all(name in built for name in dependencies):
                ordered.append(target)
                built.add(target["name"])
                pending.remove(target)
                progress = True
        if not progress:
            return None
    return ordered


def build_swift_tools(derived_data):
    products = derived_data / "Build/Products/Debug"
    manifest = json.loads(subprocess.check_output(
        ["swift", "package", "--disable-sandbox", "--package-path", str(PACKAGE), "dump-package"], cwd=ROOT))
    targets = supplemental_targets(manifest, products)
    if targets is None:
        print("Package layout changed or Xcode modules unavailable; extracting all SwiftPM products.", flush=True)
        run(["swift", "build", "--package-path", PACKAGE, "--scratch-path", derived_data / "swiftpm",
             "--arch", "arm64", "--disable-build-manifest-caching"])
        return
    output = derived_data / "supplemental"
    output.mkdir(parents=True, exist_ok=True)
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    version = next(p["version"] for p in manifest["platforms"] if p["platformName"] == "macos")
    for target in targets:
        name = target["name"]
        module = re.sub(r"[^A-Za-z0-9_]", "_", name)
        sources = sorted((PACKAGE / "Sources" / name).rglob("*.swift"))
        if not sources:
            raise RuntimeError(f"No Swift sources found for {name}")
        command = ["xcrun", "swiftc", "-c", "-whole-module-optimization", "-Onone",
                   "-swift-version", "6", "-D", "SWIFT_PACKAGE", "-D", "DEBUG",
                   "-package-name", "cortaterminal", "-module-name", module,
                   "-target", f"arm64-apple-macosx{version}", "-sdk", sdk,
                   "-I", products, "-I", output, "-F", products / "PackageFrameworks",
                   "-o", output / (module + ".o")]
        if target["type"] == "regular":
            command += ["-parse-as-library", "-emit-module", "-emit-module-path", output / (module + ".swiftmodule")]
        # A single source executable is called main.swift. Future multi-file tools
        # use the same whole-module driver invocation, without relinking the app.
        run(command + sources)


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
