#!/usr/bin/env python3
"""Check the Swift/C wrapper/RTABMapApp native symbol contract.

This is intentionally a source-level check.  It runs on hosts that do not
have the generated iOS native dependency bundle, while the macOS CI job does
a real Xcode build whenever that bundle is available.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[3]
WRAPPER_HEADER = REPOSITORY / "app/ios/RTABMapApp/NativeWrapper.hpp"
WRAPPER_SOURCE = REPOSITORY / "app/ios/RTABMapApp/NativeWrapper.cpp"
SWIFT_SOURCE = REPOSITORY / "app/ios/RTABMapApp/RTABMap.swift"
APP_HEADER = REPOSITORY / "app/android/jni/RTABMapApp.h"
APP_SOURCE = REPOSITORY / "app/android/jni/RTABMapApp.cpp"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def fail(messages: list[str]) -> None:
    for message in messages:
        print(f"native symbol contract: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    wrapper_header = read(WRAPPER_HEADER)
    wrapper_source = read(WRAPPER_SOURCE)
    swift_source = read(SWIFT_SOURCE)
    app_header = read(APP_HEADER)
    app_source = read(APP_SOURCE)

    # All exported C bridge functions are lower-camel-case and end in Native.
    # Requiring exact name-set equality catches a declaration or definition
    # being changed on only one side of the ABI.
    native_pattern = re.compile(r"\b([a-z][A-Za-z0-9_]*Native)\s*\(")
    header_exports = set(native_pattern.findall(wrapper_header))
    source_exports = set(native_pattern.findall(wrapper_source))
    swift_calls = set(native_pattern.findall(swift_source))

    # Verify that every RTABMapApp method reached through the wrapper exists in
    # both the C++ class declaration and its implementation.  This includes
    # the time-snapshot bridge without hard-coding its current symbol name.
    app_calls = set(
        re.findall(
            r"(?:native\(object\)|app)->([A-Za-z_][A-Za-z0-9_]*)\s*\(",
            wrapper_source,
        )
    )
    app_definitions = set(
        re.findall(r"\bRTABMapApp::([A-Za-z_][A-Za-z0-9_]*)\s*\(", app_source)
    )
    app_declarations = set(
        re.findall(
            r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\([^;{}]*\)\s*(?:const\s*)?;",
            app_header,
            flags=re.DOTALL,
        )
    )

    errors: list[str] = []
    if not header_exports:
        errors.append("NativeWrapper.hpp exposes no Native functions")
    for name in sorted(header_exports - source_exports):
        errors.append(f"{name} is declared in NativeWrapper.hpp but not defined")
    for name in sorted(source_exports - header_exports):
        errors.append(f"{name} is defined in NativeWrapper.cpp but not declared")
    for name in sorted(swift_calls - header_exports):
        errors.append(f"Swift calls {name}, which is absent from NativeWrapper.hpp")
    for name in sorted(app_calls - app_declarations):
        errors.append(f"wrapper calls RTABMapApp::{name}, which is not declared")
    for name in sorted(app_calls - app_definitions):
        errors.append(f"wrapper calls RTABMapApp::{name}, which is not defined")

    required_snapshot_symbol = "getNodeTimeSnapshotNative"
    if required_snapshot_symbol not in header_exports:
        errors.append("atomic node-time snapshot C ABI is missing")
    if "getLastNodeNative" in header_exports | source_exports | swift_calls:
        errors.append("deprecated split getLastNodeNative ABI is still exposed or used")
    if "getNodeTimeSnapshot" not in app_calls:
        errors.append("NativeWrapper does not call RTABMapApp::getNodeTimeSnapshot")
    normalized_wrapper_header = re.sub(r"\s+", " ", wrapper_header)
    snapshot_abi = re.compile(
        r"bool getNodeTimeSnapshotNative\(const void \*object, int32_t \* nodeId, "
        r"int32_t \* nodeMapId, double \* nodeStamp, double \* epochOffset, "
        r"uint64_t \* generation, float \* nodeX, float \* nodeY, float \* nodeZ, "
        r"float \* nodeQx, float \* nodeQy, float \* nodeQz, float \* nodeQw\);"
    )
    if snapshot_abi.search(normalized_wrapper_header) is None:
        errors.append(
            "atomic node-time C ABI types do not include exact node identity/pose"
        )
    for field in (
        "nodeId", "nodeMapId", "nodeStamp", "epochOffset", "generation",
        "nodeX", "nodeY", "nodeZ", "nodeQx", "nodeQy", "nodeQz", "nodeQw",
    ):
        if field not in app_header:
            errors.append(f"NodeTimeSnapshot field {field} is missing")
    for required_source_token in (
        "boost::defer_lock",
        "boost::lock(cameraLock, rtabmapLock)",
        "opengl_world_T_rtabmap_world * signature->getPose()",
        "++nodeTimeSnapshotGeneration_",
        "std::numeric_limits<std::uint64_t>::max()",
    ):
        if required_source_token not in app_source:
            errors.append(
                f"atomic snapshot implementation is missing {required_source_token}"
            )
    for zero_assignment in (
        "*nodeId = 0",
        "*nodeMapId = 0",
        "*nodeStamp = 0.0",
        "*epochOffset = 0.0",
        "*generation = 0",
    ):
        if zero_assignment not in wrapper_source:
            errors.append(f"snapshot failure output reset is missing: {zero_assignment}")
    latest_binding_match = re.search(
        r"func\s+latestNodeBinding\b(?P<body>.*?)\n\s*func\s+nodeTimebase\b",
        swift_source,
        flags=re.DOTALL,
    )
    if latest_binding_match is None:
        errors.append("Swift latestNodeBinding implementation was not found")
    else:
        latest_binding_body = latest_binding_match.group("body")
        if latest_binding_body.count("getNodeTimeSnapshotNative") != 1:
            errors.append("Swift latestNodeBinding must call one atomic native snapshot")
        if "getNodeTimeOffsetNative" in latest_binding_body:
            errors.append("Swift latestNodeBinding still performs a split offset read")

    if errors:
        fail(errors)

    print(
        "native symbol contract passed: "
        f"{len(header_exports)} C exports, "
        f"{len(swift_calls)} Swift calls, "
        f"{len(app_calls)} RTABMapApp calls"
    )


if __name__ == "__main__":
    main()
