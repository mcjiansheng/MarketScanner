"""Bounded grid queries for prior-map structural elements."""

from __future__ import annotations

import math
from pathlib import Path
from typing import Any, Iterable

from .prior_map_schema import load_json


class PriorMapSpatialIndex:
    def __init__(
        self,
        cell_size_m: float,
        floor_cells: dict[str, dict[str, list[str]]],
        floor_road_cells: dict[str, dict[str, list[str]]],
        elements: dict[str, dict[str, Any]],
    ) -> None:
        if cell_size_m <= 0:
            raise ValueError("Spatial-index cell size must be positive.")
        self.cell_size_m = float(cell_size_m)
        self.floor_cells = floor_cells
        self.floor_road_cells = floor_road_cells
        self.elements = elements

    @classmethod
    def load(cls, package_directory: Path | str) -> "PriorMapSpatialIndex":
        root = Path(package_directory)
        payload = load_json(root / "spatial_index.json")
        elements_payload = load_json(root / "elements.json")
        elements = {
            str(item["id"]): item for item in elements_payload.get("elements", [])
        }
        floor_cells = {
            str(floor_id): floor.get("cells", {})
            for floor_id, floor in payload.get("floors", {}).items()
        }
        floor_road_cells = {
            str(floor_id): floor.get("road_cells", {})
            for floor_id, floor in payload.get("floors", {}).items()
        }
        return cls(
            float(payload["cell_size_m"]),
            floor_cells,
            floor_road_cells,
            elements,
        )

    def _query_cells(
        self,
        floor_cells: dict[str, dict[str, list[str]]],
        floor_id: str,
        x_m: float,
        y_m: float,
        radius_m: float,
    ) -> list[str]:
        radius = max(0.0, float(radius_m))
        minimum_x = math.floor((float(x_m) - radius) / self.cell_size_m)
        maximum_x = math.floor((float(x_m) + radius) / self.cell_size_m)
        minimum_y = math.floor((float(y_m) - radius) / self.cell_size_m)
        maximum_y = math.floor((float(y_m) + radius) / self.cell_size_m)
        cells = floor_cells.get(str(floor_id), {})
        identifiers: set[str] = set()
        for cell_x in range(minimum_x, maximum_x + 1):
            for cell_y in range(minimum_y, maximum_y + 1):
                identifiers.update(cells.get(f"{cell_x},{cell_y}", []))
        return sorted(identifiers)

    def query_ids(
        self,
        floor_id: str,
        x_m: float,
        y_m: float,
        radius_m: float = 0.0,
    ) -> list[str]:
        return self._query_cells(
            self.floor_cells,
            floor_id,
            x_m,
            y_m,
            radius_m,
        )

    def query_road_edge_ids(
        self,
        floor_id: str,
        x_m: float,
        y_m: float,
        radius_m: float = 0.0,
    ) -> list[str]:
        return self._query_cells(
            self.floor_road_cells,
            floor_id,
            x_m,
            y_m,
            radius_m,
        )

    def query(
        self,
        floor_id: str,
        x_m: float,
        y_m: float,
        radius_m: float = 0.0,
        shape_types: Iterable[str] | None = None,
    ) -> list[dict[str, Any]]:
        allowed = set(shape_types) if shape_types is not None else None
        result = [
            self.elements[identifier]
            for identifier in self.query_ids(floor_id, x_m, y_m, radius_m)
            if identifier in self.elements
            and (allowed is None or self.elements[identifier].get("shape_type") in allowed)
        ]
        return result
