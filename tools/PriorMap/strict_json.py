"""P7R6C: shared strict JSON helpers for every formal JSON reader.

The offline localization reader, the prior-map schema reader and the
XLSX converter must not drift into separate implementations of the same
fail-closed contract. All formal JSON documents are decoded through the
helpers in this module:

- non-finite numbers are rejected (``allow_nan`` semantics, fail closed);
- duplicate object keys are rejected through ``object_pairs_hook`` before
  ``json.loads`` can silently apply last-key-wins;
- nesting depth can be measured iteratively without recursion.
"""

from __future__ import annotations

import json
from typing import Any


class DuplicateJSONKeyError(ValueError):
    """Raised by the object_pairs_hook when one JSON object repeats a key.

    ``json.loads`` would otherwise apply last-key-wins and silently drop
    the first value; a fail-closed evidence contract must reject the
    ambiguity before any schema decision is made on the surviving value.
    """

    def __init__(self, key: str) -> None:
        super().__init__(f"Duplicate JSON key: {key}")
        self.key = key


def reject_nonfinite_json(value: str) -> None:
    raise ValueError(f"Non-finite JSON number is forbidden: {value}")


def reject_duplicate_object_pairs(
    pairs: list[tuple[str, Any]],
) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateJSONKeyError(key)
        result[key] = value
    return result


def json_nesting_depth(value: Any) -> int:
    """Iterative maximum nesting depth of a decoded JSON value. Never
    recurses, so a deeply nested document cannot overflow the Python
    stack while being measured."""
    max_depth = 0
    stack: list[tuple[Any, int]] = [(value, 1)]
    while stack:
        node, depth = stack.pop()
        if isinstance(node, dict):
            max_depth = max(max_depth, depth)
            for child in node.values():
                stack.append((child, depth + 1))
        elif isinstance(node, list):
            max_depth = max(max_depth, depth)
            for child in node:
                stack.append((child, depth + 1))
    return max_depth


def load_strict_json_bytes(data: bytes, *, name: str) -> Any:
    """Decode one formal JSON document from already-stable bytes with the
    shared fail-closed contract (strict UTF-8, no NaN/Infinity, no
    duplicate object keys)."""
    try:
        return json.loads(
            data.decode("utf-8", errors="strict"),
            parse_constant=reject_nonfinite_json,
            object_pairs_hook=reject_duplicate_object_pairs,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError, RecursionError) as exc:
        raise StrictJSONError(f"{name} is not valid strict JSON: {exc}") from exc


class StrictJSONError(ValueError):
    """Stable wrapper for strict JSON decode failures."""
