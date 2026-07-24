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
    args = parser.parse_args(argv)
    result = validate_package(args.package)
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if result["valid"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
