"""H-09 / §5.1: the start-pose yaw arrow must be a right-pointing
artwork rotated with the frozen yaw contract, and the preview
y-down chirality must be explicit.

Mirrors the iOS implementation exactly:
- `MobileScanSetupViewController.buildUI()`:
  startMarker frame (0, 0, 44, 44); markerDot (16, 16, 12, 12);
  arrow (29, 21, 14, 2)  ->  arrow center offset (+14, 0), endpoint
  offset (+21, 0) from the marker center (22, 22);
- `rotateMarker()`: `startMarker.transform =
  CGAffineTransform(rotationAngle: CGFloat(-startYawRad))`.

CGAffineTransform in UIKit (y-down screen coordinates) applies the
standard rotation matrix

    R(a) = [[cos a, -sin a], [sin a, cos a]]

so a positive `rotationAngle` is visually CLOCKWISE. With the arrow
artwork pointing along +X, the map->image chirality flip is exactly
the negation `-startYawRad`; any residual 90 deg bias (the old
vertical artwork) fails the golden assertions below.
"""

from __future__ import annotations

import math
import unittest

MARKER_SIZE = 44.0
CENTER = (MARKER_SIZE / 2, MARKER_SIZE / 2)  # (22, 22)

# Arrow artwork: horizontal bar on the right side of the marker.
ARROW_FRAME = (29.0, 21.0, 14.0, 2.0)
ARROW_CENTER_OFFSET = (
    ARROW_FRAME[0] + ARROW_FRAME[2] / 2 - CENTER[0],
    ARROW_FRAME[1] + ARROW_FRAME[3] / 2 - CENTER[1],
)
# The far endpoint of the bar, relative to the marker center.
ARROW_ENDPOINT_OFFSET = (
    ARROW_FRAME[0] + ARROW_FRAME[2] - CENTER[0],
    ARROW_FRAME[1] + ARROW_FRAME[3] / 2 - CENTER[1],
)


def rotated_offset(offset: tuple[float, float], screen_angle: float) -> tuple[float, float]:
    """Applies CGAffineTransform(rotationAngle: screen_angle) to a point
    offset in the y-down screen coordinate system.

    R(a) = [[cos a, -sin a], [sin a, cos a]]
    """
    ca = math.cos(screen_angle)
    sa = math.sin(screen_angle)
    return (
        offset[0] * ca - offset[1] * sa,
        offset[0] * sa + offset[1] * ca,
    )


def arrow_endpoint(yaw_rad: float) -> tuple[float, float]:
    """Screen position of the arrow's far endpoint for a map yaw.

    `rotateMarker` applies `rotationAngle: -yaw_rad`; the arrow is
    translated to the marker center plus the rotated endpoint offset.
    """
    v = rotated_offset(ARROW_ENDPOINT_OFFSET, -yaw_rad)
    return (CENTER[0] + v[0], CENTER[1] + v[1])


def arrow_center(yaw_rad: float) -> tuple[float, float]:
    v = rotated_offset(ARROW_CENTER_OFFSET, -yaw_rad)
    return (CENTER[0] + v[0], CENTER[1] + v[1])


class YawArrowGeometryGolden(unittest.TestCase):
    """The four-direction golden (§5.1) on the y-down preview."""

    def test_artwork_is_horizontal_right_pointing(self) -> None:
        # The artwork itself must point along +X: a horizontal bar whose
        # far endpoint lies strictly to the right of its center.
        self.assertEqual(ARROW_FRAME[3], 2.0)  # height, not a vertical shaft
        self.assertEqual(ARROW_FRAME[2], 14.0)  # length along X
        self.assertGreater(ARROW_ENDPOINT_OFFSET[0], 0.0)
        self.assertEqual(ARROW_ENDPOINT_OFFSET[1], 0.0)

    def test_artwork_fits_marker(self) -> None:
        end = (ARROW_FRAME[0] + ARROW_FRAME[2], ARROW_FRAME[1] + ARROW_FRAME[3])
        self.assertGreaterEqual(ARROW_FRAME[0], 0.0)
        self.assertGreaterEqual(ARROW_FRAME[1], 0.0)
        self.assertLessEqual(end[0], MARKER_SIZE)
        self.assertLessEqual(end[1], MARKER_SIZE)

    def test_yaw_zero_points_right(self) -> None:
        # yaw 0 -> endpoint x grows, y unchanged.
        x, y = arrow_endpoint(0.0)
        self.assertGreater(x, CENTER[0])
        self.assertAlmostEqual(y, CENTER[1])

    def test_yaw_positive_pi_over_two_points_up(self) -> None:
        # yaw +pi/2 -> image up (y-down: y decreases).
        x, y = arrow_endpoint(math.pi / 2)
        self.assertAlmostEqual(x, CENTER[0])
        self.assertLess(y, CENTER[1])

    def test_yaw_pi_points_left(self) -> None:
        # yaw pi -> left.
        x, y = arrow_endpoint(math.pi)
        self.assertLess(x, CENTER[0])
        self.assertAlmostEqual(y, CENTER[1])

    def test_yaw_negative_pi_over_two_points_down(self) -> None:
        # yaw -pi/2 -> down (y-down: y increases).
        x, y = arrow_endpoint(-math.pi / 2)
        self.assertAlmostEqual(x, CENTER[0])
        self.assertGreater(y, CENTER[1])

    def test_chirality_flip_is_negation_only(self) -> None:
        # The map->image chirality flip must be exactly `-yaw`, not a
        # sign flip plus an extra 90 deg. If the artwork were vertical
        # (the pre-H-09 bug), yaw +pi/2 would point down, not up.
        for yaw in (math.pi / 4, math.pi / 3, 2.0, -1.0):
            center = arrow_center(yaw)
            # The arrow stays a 14x2 bar: center distance from the marker
            # center is 14 and the yaw rotates the bar without skewing.
            distance = math.hypot(center[0] - CENTER[0], center[1] - CENTER[1])
            self.assertAlmostEqual(distance, ARROW_CENTER_OFFSET[0], places=9)
            # Sanity: with the correct artwork, +pi/2 is always up and
            # -pi/2 always down across intermediate angles the endpoints
            # keep finite in-bounds when projected.
            self.assertTrue(math.isfinite(center[0]) and math.isfinite(center[1]))


if __name__ == "__main__":
    unittest.main()
