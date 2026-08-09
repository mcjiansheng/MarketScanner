"""Versioned semantic roles for prior-map source elements.

Every importer, compiler, renderer and validator must classify a
``shapeType`` through this module.  Geometry fields alone are not evidence
that an object is a shelf or a localization structure.
"""

from __future__ import annotations

from typing import Final


ELEMENT_ROLE_CONTRACT_VERSION: Final = 1

ROLE_SHELF: Final = "shelf"
ROLE_FIXED_STRUCTURE: Final = "fixed_structure"
ROLE_ROAD: Final = "road"
ROLE_PRESENTATION_ONLY: Final = "presentation_only"
ROLE_UNSUPPORTED: Final = "unsupported"

SHELF_TYPES: Final[frozenset[str]] = frozenset({"MapShelf"})
FIXED_STRUCTURE_TYPES: Final[frozenset[str]] = frozenset(
    {"MapTable", "MapTableFeature", "MapPillar"}
)
ROAD_TYPES: Final[frozenset[str]] = frozenset({"MapCross", "MapRoadPoint"})
PRESENTATION_ONLY_TYPES: Final[frozenset[str]] = frozenset(
    {"Circle", "Rect", "MapMark"}
)
ACTIVE_TYPES: Final[frozenset[str]] = (
    SHELF_TYPES | FIXED_STRUCTURE_TYPES | ROAD_TYPES
)
STRUCTURE_TYPES: Final[frozenset[str]] = SHELF_TYPES | FIXED_STRUCTURE_TYPES
RECTANGLE_TYPES: Final[frozenset[str]] = STRUCTURE_TYPES


def role_for(shape_type: str) -> str:
    """Return the sole authoritative semantic role for ``shape_type``."""

    if shape_type in SHELF_TYPES:
        return ROLE_SHELF
    if shape_type in FIXED_STRUCTURE_TYPES:
        return ROLE_FIXED_STRUCTURE
    if shape_type in ROAD_TYPES:
        return ROLE_ROAD
    if shape_type in PRESENTATION_ONLY_TYPES:
        return ROLE_PRESENTATION_ONLY
    return ROLE_UNSUPPORTED


def role_contract_payload() -> dict[str, object]:
    """Stable manifest representation of the role table."""

    return {
        "version": ELEMENT_ROLE_CONTRACT_VERSION,
        "shelf": sorted(SHELF_TYPES),
        "fixed_structure": sorted(FIXED_STRUCTURE_TYPES),
        "road": sorted(ROAD_TYPES),
        "presentation_only": sorted(PRESENTATION_ONLY_TYPES),
    }
