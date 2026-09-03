"""Map-anchored static-occluder classification for shelf observation gaps.

C-3a redesign (2026-09-03). Field observation: scanning advances along a
shelf at roughly 1-2 m/s, so a standing customer or parked cart occludes its
shelf segment for the *entire* scanning pass. Occlusion duration therefore
carries no information and must not be used to decide whether a blocked
shelf "exists". The prior map is authoritative (S-1): if the map says the
position is a continuous shelf and the observation record shows an interior
gap bounded by observations on both sides, the gap is classified as a
static occluder and the shelf behind it is presumed present but unobserved.

Moving customers remain handled by the temporal consistency filter
(`DynamicShelfEvidenceFilter` on iOS): their depth fragments move between
frames and fall out of the elevated-evidence stability gate. This module
never arbitrates map correctness and never writes a sidecar contract field;
it is a classifier consumed by shelf-loop confirmation and PC review.

Classification of each gap along a mapped shelf's long axis:

- ``static_occluder``: interior gap, ``min_gap_m <= length <= max_occluder_m``,
  observations on both sides. ``presumed_shelf_present=True``.
- ``unclassified_large_gap``: interior gap longer than ``max_occluder_m``.
  No presence assertion (``presumed_shelf_present=None``); it may be a moved
  shelf, a fixture, or a wide installation and needs review.
- ``shelf_end_region``: gap touching either physical end of the mapped shelf.
  No assertion; endcaps are legitimately short-observed.

Interior gaps below ``min_gap_m`` are treated as observation sampling noise
and merged into coverage instead of being classified.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Iterable, Optional, Sequence

MIN_STATIC_OCCLUDER_GAP_M = 0.3
MAX_STATIC_OCCLUDER_GAP_M = 2.5

CLASS_STATIC_OCCLUDER = "static_occluder"
CLASS_UNCLASSIFIED_LARGE_GAP = "unclassified_large_gap"
CLASS_SHELF_END_REGION = "shelf_end_region"

_ALL_CLASSES = (
    CLASS_STATIC_OCCLUDER,
    CLASS_UNCLASSIFIED_LARGE_GAP,
    CLASS_SHELF_END_REGION,
)


@dataclass(frozen=True)
class ShelfOcclusionGap:
    """One classified observation gap along a mapped shelf's long axis.

    ``start_m`` is measured from the shelf start along its long axis.
    ``presumed_shelf_present`` is ``True`` only for static occluders; it is
    ``None`` wherever no presence assertion is permitted.
    """

    start_m: float
    length_m: float
    classification: str
    presumed_shelf_present: Optional[bool]


def _require_finite(value: float, field: str) -> float:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        raise ValueError(f"{field} must be a finite number, got {value!r}")
    value = float(value)
    if not math.isfinite(value):
        raise ValueError(f"{field} must be finite, got {value!r}")
    return value


def _merge_intervals(
    intervals: Sequence[Sequence[float]],
    shelf_length_m: float,
    min_gap_m: float,
) -> list[tuple[float, float]]:
    """Validate, clip to [0, length], sort and merge observed coverage.

    Intervals closer than ``min_gap_m`` are merged, because gaps below the
    minimum occluder width are observation sampling noise rather than
    evidence of an occluding body.
    """
    clipped: list[tuple[float, float]] = []
    for index, item in enumerate(intervals):
        if not isinstance(item, (list, tuple)) or len(item) != 2:
            raise ValueError(
                f"interval {index} must be a (start_m, end_m) pair, "
                f"got {item!r}")
        start = _require_finite(item[0], f"interval {index} start_m")
        end = _require_finite(item[1], f"interval {index} end_m")
        if start > end:
            raise ValueError(
                f"interval {index} start_m {start} exceeds end_m {end}")
        start = max(0.0, min(shelf_length_m, start))
        end = max(0.0, min(shelf_length_m, end))
        if end - start <= 0.0:
            continue
        clipped.append((start, end))
    clipped.sort()
    merged: list[list[float]] = []
    for start, end in clipped:
        if merged and start <= merged[-1][1] + min_gap_m:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])
    return [(start, end) for start, end in merged]


def classify_shelf_observation_gaps(
    shelf_length_m: float,
    observed_intervals: Iterable[Sequence[float]],
    *,
    min_gap_m: float = MIN_STATIC_OCCLUDER_GAP_M,
    max_occluder_m: float = MAX_STATIC_OCCLUDER_GAP_M,
) -> list[ShelfOcclusionGap]:
    """Classify observation gaps along one mapped continuous shelf.

    ``observed_intervals`` are (start_m, end_m) coverage spans along the
    shelf long axis, in any order; values outside the shelf are clipped.
    Returns gaps ordered by ``start_m``. Raises ``ValueError`` on invalid
    input (fail closed: never guess on malformed evidence).
    """
    length = _require_finite(shelf_length_m, "shelf_length_m")
    if length <= 0.0:
        raise ValueError(f"shelf_length_m must be positive, got {length}")
    min_gap = _require_finite(min_gap_m, "min_gap_m")
    max_occluder = _require_finite(max_occluder_m, "max_occluder_m")
    if min_gap <= 0.0 or max_occluder < min_gap:
        raise ValueError(
            f"requires 0 < min_gap_m <= max_occluder_m, got "
            f"{min_gap}, {max_occluder}")
    intervals = list(observed_intervals)
    coverage = _merge_intervals(intervals, length, min_gap)

    gaps: list[ShelfOcclusionGap] = []
    boundaries: list[tuple[float, float]] = []
    cursor = 0.0
    for start, end in coverage:
        if start - cursor >= min_gap:
            boundaries.append((cursor, start))
        cursor = end
    if length - cursor >= min_gap:
        boundaries.append((cursor, length))

    for gap_start, gap_end in boundaries:
        gap_length = gap_end - gap_start
        touches_start = gap_start <= 0.0
        touches_end = gap_end >= length
        if touches_start or touches_end:
            gaps.append(ShelfOcclusionGap(
                start_m=gap_start,
                length_m=gap_length,
                classification=CLASS_SHELF_END_REGION,
                presumed_shelf_present=None))
        elif gap_length > max_occluder:
            gaps.append(ShelfOcclusionGap(
                start_m=gap_start,
                length_m=gap_length,
                classification=CLASS_UNCLASSIFIED_LARGE_GAP,
                presumed_shelf_present=None))
        else:
            # Map-anchored rule: the map says this is continuous shelf, both
            # flanks are observed, so the blocking body is static and the
            # shelf behind it exists but was never observed.
            gaps.append(ShelfOcclusionGap(
                start_m=gap_start,
                length_m=gap_length,
                classification=CLASS_STATIC_OCCLUDER,
                presumed_shelf_present=True))
    return gaps


__all__ = [
    "MIN_STATIC_OCCLUDER_GAP_M",
    "MAX_STATIC_OCCLUDER_GAP_M",
    "CLASS_STATIC_OCCLUDER",
    "CLASS_UNCLASSIFIED_LARGE_GAP",
    "CLASS_SHELF_END_REGION",
    "ShelfOcclusionGap",
    "classify_shelf_observation_gaps",
]
