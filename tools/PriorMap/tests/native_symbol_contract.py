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
