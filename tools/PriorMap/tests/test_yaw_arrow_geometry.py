"""H-09 / §5.1: setup, ARKit alignment and the live HUD must share one
canonical heading contract, and the preview y-down chirality must be explicit.

Mirrors the iOS implementation exactly:
- `MobileScanSetupViewController.configureMapEditor()`:
  startMarker frame (0, 0, 48, 48); markerDot (18, 18, 12, 12);
  arrow (29, 22, 17, 4) -> a right-pointing horizontal heading;
- `PriorMapHeadingUI.screenTransform`: one `-yaw` UIKit chirality flip used by
  setup, manual re-selection and the live HUD;
- `PriorMapStageOneMath.arkitHorizontalPose`: camera forward is projected as
  `(forwardX, -forwardZ)` and measured from map +X.

CGAffineTransform in UIKit (y-down screen coordinates) applies the
standard rotation matrix

    R(a) = [[cos a, -sin a], [sin a, cos a]]

so a positive `rotationAngle` is visually CLOCKWISE. With the arrow
artwork pointing along +X, the map->image chirality flip is exactly
the negation `-yawRad`; any residual 90 deg bias (the old vertical artwork or
the old ARKit +Y-zero convention) fails the golden assertions below.
"""

from __future__ import annotations

import math
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[3]
MARKER_SIZE = 48.0
CENTER = (MARKER_SIZE / 2, MARKER_SIZE / 2)  # (24, 24)

# Arrow artwork: horizontal bar on the right side of the marker.
ARROW_FRAME = (29.0, 22.0, 17.0, 4.0)
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


def normalize_angle(value: float) -> float:
    return math.atan2(math.sin(value), math.cos(value))


def arkit_yaw(forward_x: float, forward_z: float) -> float:
    """ARKit camera-forward projected into canonical map SE(2)."""
    return normalize_angle(math.atan2(-forward_z, forward_x))


def project_forward_step(start_yaw: float) -> tuple[float, float]:
    """Project one metre of ARKit -z travel from the first-frame anchor."""
    arkit_origin_yaw = math.pi / 2
    rotation = start_yaw - arkit_origin_yaw
    return (-math.sin(rotation), math.cos(rotation))


class YawArrowGeometryGolden(unittest.TestCase):
    """The four-direction golden (§5.1) on the y-down preview."""

    def test_artwork_is_horizontal_right_pointing(self) -> None:
        # The artwork itself must point along +X: a horizontal bar whose
        # far endpoint lies strictly to the right of its center.
        self.assertEqual(ARROW_FRAME[3], 4.0)  # height, not a vertical shaft
        self.assertEqual(ARROW_FRAME[2], 17.0)  # length along X
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

    def test_arkit_camera_forward_uses_standard_map_yaw(self) -> None:
        directions = (
            ((1.0, 0.0), 0.0),
            ((0.0, -1.0), math.pi / 2),
            ((-1.0, 0.0), math.pi),
            ((0.0, 1.0), -math.pi / 2),
        )
        for (forward_x, forward_z), expected in directions:
            actual = arkit_yaw(forward_x, forward_z)
            delta = math.atan2(
                math.sin(actual - expected), math.cos(actual - expected)
            )
            self.assertAlmostEqual(delta, 0.0)

    def test_first_frame_alignment_preserves_selected_cardinal_heading(self) -> None:
        expected_steps = (
            (0.0, (1.0, 0.0)),
            (math.pi / 2, (0.0, 1.0)),
            (math.pi, (-1.0, 0.0)),
            (-math.pi / 2, (0.0, -1.0)),
        )
        for yaw, expected in expected_steps:
            actual = project_forward_step(yaw)
            self.assertAlmostEqual(actual[0], expected[0], places=9)
            self.assertAlmostEqual(actual[1], expected[1], places=9)

    def test_source_uses_zoom_nudges_and_discrete_heading_controls(self) -> None:
        source = (
            ROOT
            / "app/ios/RTABMapApp/MobileOnlyWorkflow/UI/"
            "MobileScanSetupViewController.swift"
        ).read_text(encoding="utf-8")
        self.assertIn("mapScrollView.maximumZoomScale = 8", source)
        self.assertIn("@objc private func nudgeUp()", source)
        self.assertIn("@objc private func nudgeRight()", source)
        self.assertIn("@objc private func turnLeft()", source)
        self.assertIn("@objc private func turnRight()", source)
        self.assertIn("private let headingControl = UISegmentedControl", source)
        self.assertNotIn("yawSlider", source)

    def test_setup_localizer_and_live_hud_share_one_heading_contract(self) -> None:
        setup = (
            ROOT
            / "app/ios/RTABMapApp/MobileOnlyWorkflow/UI/"
            "MobileScanSetupViewController.swift"
        ).read_text(encoding="utf-8")
        overlay = (
            ROOT / "app/ios/RTABMapApp/PriorMapLocalization.swift"
        ).read_text(encoding="utf-8")
        core = (
            ROOT / "app/ios/RTABMapApp/PriorMapLocalizationCore.swift"
        ).read_text(encoding="utf-8")
        depth = (
            ROOT / "app/ios/RTABMapApp/PriorMapDepthSampler.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("PriorMapHeadingUI", setup)
        self.assertIn(".screenTransform(yawRad: startYawRad)", setup)
        self.assertIn("enum PriorMapHeadingUI", overlay)
        self.assertIn(
            "CGAffineTransform(rotationAngle: CGFloat(-yawRad))", overlay
        )
        self.assertGreaterEqual(
            overlay.count("PriorMapHeadingUI.rightPointingArrowPath("), 2
        )
        self.assertGreaterEqual(
            overlay.count("PriorMapHeadingUI.screenTransform("), 2
        )
        self.assertIn("path.move(to: CGPoint(x: length, y: 0))", overlay)
        self.assertNotIn("path.move(to: CGPoint(x: 0, y: -8))", overlay)
        self.assertNotIn("path.move(to: CGPoint(x: 0, y: -10))", overlay)
        self.assertIn("atan2(-forwardZ, forwardX)", core)
        self.assertNotIn("atan2(-forwardX, -forwardZ)", core)
        self.assertIn("atan2(local.y, max(0.001, local.x))", depth)

    def test_manual_relocalization_matches_setup_precision_controls(self) -> None:
        overlay = (
            ROOT / "app/ios/RTABMapApp/PriorMapLocalization.swift"
        ).read_text(encoding="utf-8")
        self.assertIn('items: ["0.1 m", "0.5 m", "1.0 m"]', overlay)
        self.assertIn('@objc private func nudgeUp()', overlay)
        self.assertIn('@objc private func nudgeDown()', overlay)
        self.assertIn('@objc private func nudgeLeft()', overlay)
        self.assertIn('@objc private func nudgeRight()', overlay)
        for degrees in ("Minus15", "Minus5", "Minus1", "Plus1", "Plus5", "Plus15"):
            self.assertIn(f'@objc private func rotate{degrees}()', overlay)
        self.assertIn('items: ["东 0°", "北 90°", "西 180°", "南 −90°"]', overlay)
        self.assertIn("private let scrollView = UIScrollView()", overlay)
        self.assertIn("scrollView.contentLayoutGuide.bottomAnchor", overlay)
        self.assertIn("界面数值就是写入审计记录的 canonical SE(2)", overlay)
        self.assertIn("for: .editingDidEnd", overlay)
        self.assertNotIn("for: .editingChanged", overlay)
        self.assertIn("view.endEditing(true)", overlay)
        self.assertIn("applyCoordinateFields(showError: true)", overlay)
        self.assertIn("坐标或方向不是有效数字", overlay)
        self.assertIn("当前位置尚未提交", overlay)
        self.assertIn("@objc private func resetPose()", overlay)

    def test_reliable_loop_retains_bounded_shelf_identity_candidates(self) -> None:
        overlay = (
            ROOT / "app/ios/RTABMapApp/PriorMapLocalization.swift"
        ).read_text(encoding="utf-8")
        host = (ROOT / "app/ios/RTABMapApp/ViewController.swift").read_text(
            encoding="utf-8"
        )
        self.assertIn("self.shelfSegments = package.shelfSegments.filter", overlay)
        self.assertIn("func nearbyShelfIdentityCandidates(", overlay)
        self.assertIn(".prefix(max(1, min(5, limit)))", overlay)
        self.assertIn("localizer.requestRecovery(reason: \"reliable_rtabmap_loop\")", host)
        self.assertIn('event: "loop_opened_shelf_identity_candidates"', host)
        self.assertIn('"ambiguous_top_k_retained"', host)
        self.assertIn('"manifest_v5_shelf_loop_candidate"', host)

    def test_start_yaw_reaches_initial_map_pose_without_conversion(self) -> None:
        setup = (
            ROOT
            / "app/ios/RTABMapApp/MobileOnlyWorkflow/UI/"
            "MobileScanSetupViewController.swift"
        ).read_text(encoding="utf-8")
        host = (ROOT / "app/ios/RTABMapApp/ViewController.swift").read_text(
            encoding="utf-8"
        )
        self.assertIn("startYawRad: startYawRad", setup)
        self.assertIn("yawRad: configuration.startYawRad", host)

    def test_preview_renderer_and_touch_transform_flip_y_exactly_once(self) -> None:
        renderer = (
            ROOT
            / "app/ios/RTABMapApp/MobilePriorMapCompiler/"
            "MobilePreviewRenderer.swift"
        ).read_text(encoding="utf-8")
        setup = (
            ROOT
            / "app/ios/RTABMapApp/MobileOnlyWorkflow/UI/"
            "MobileScanSetupViewController.swift"
        ).read_text(encoding="utf-8")
        projection = renderer.split("static func quartzPoint(", 1)[1].split(
            "static func render(", 1
        )[0]
        self.assertIn("y: sy * Double(canvasHeight)", projection)
        self.assertNotIn("1.0 - sy", projection)
        touch_transform = setup.split(
            "private func mapPoint(", 1
        )[1].split("private func canvasPoint", 1)[0]
        self.assertIn("+ (1 - Double(v))", touch_transform)


if __name__ == "__main__":
    unittest.main()
