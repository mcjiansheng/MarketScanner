#!/usr/bin/env python3
"""Validate a versioned MarketScanner prior-map package."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Iterable

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from PriorMap.prior_map_schema import validate_package
else:
    from .prior_map_schema import validate_package


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Validate a MarketScanner prior-map package.")
    parser.add_argument("package", type=Path)
    parser.add_argument(
        "--allow-legacy-v2-identifier-for-diagnostics",
        action="store_true",
        help=(
            "accept the pre-canonical uppercase v2 ID only for read-only "
            "diagnosis; the package remains invalid for loading/localization"
        ),
    )
    args = parser.parse_args(argv)
    result = validate_package(
        args.package,
        allow_legacy_v2_identifier_for_diagnostics=(
            args.allow_legacy_v2_identifier_for_diagnostics
        ),
    )
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if result["valid"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
