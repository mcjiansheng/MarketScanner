"use strict";

(function installAnchorGeometry(root) {
  const TWO_PI = Math.PI * 2;

  function finiteNumber(value, label) {
    const number = Number(value);
    if (!Number.isFinite(number)) throw new TypeError(`${label} must be finite`);
    return number;
  }

  function normalizeRadians(value) {
    const angle = finiteNumber(value, "angle");
    const normalized = ((angle + Math.PI) % TWO_PI + TWO_PI) % TWO_PI - Math.PI;
    return normalized <= -Math.PI ? Math.PI : normalized;
  }

  function normalizeDegrees(value) {
    return normalizeRadians(finiteNumber(value, "degrees") * Math.PI / 180) * 180 / Math.PI;
  }

  function canonicalBounds(rawBounds) {
    const bounds = rawBounds || {};
    const minX = finiteNumber(bounds.min_x_m, "min_x_m");
    const minY = finiteNumber(bounds.min_y_m, "min_y_m");
    const maxX = finiteNumber(bounds.max_x_m, "max_x_m");
    const maxY = finiteNumber(bounds.max_y_m, "max_y_m");
    if (maxX < minX || maxY < minY) {
      throw new RangeError("canonical bounds are invalid");
    }
    return Object.freeze({ minX, minY, maxX, maxY });
  }

  function clampCanonicalPoint(point, rawBounds) {
    const x = finiteNumber(point[0], "x");
    const y = finiteNumber(point[1], "y");
    const bounds = canonicalBounds(rawBounds);
    return [
      Math.min(bounds.maxX, Math.max(bounds.minX, x)),
      Math.min(bounds.maxY, Math.max(bounds.minY, y)),
    ];
  }

  function createProjection(bounds, width, height, padding) {
    const minX = finiteNumber(bounds.minX, "minX");
    const minY = finiteNumber(bounds.minY, "minY");
    const maxX = finiteNumber(bounds.maxX, "maxX");
    const maxY = finiteNumber(bounds.maxY, "maxY");
    const canvasWidth = finiteNumber(width, "width");
    const canvasHeight = finiteNumber(height, "height");
    const inset = finiteNumber(padding, "padding");
    if (maxX <= minX || maxY <= minY || canvasWidth <= inset * 2 || canvasHeight <= inset * 2) {
      throw new RangeError("projection bounds are empty");
    }
    return Object.freeze({
      minX,
      minY,
      maxX,
      maxY,
      width: canvasWidth,
      height: canvasHeight,
      padding: inset,
      scale: Math.min(
        (canvasWidth - inset * 2) / (maxX - minX),
        (canvasHeight - inset * 2) / (maxY - minY),
      ),
    });
  }

  function project(point, projection) {
    const x = finiteNumber(point[0], "x");
    const y = finiteNumber(point[1], "y");
    return [
      projection.padding + (x - projection.minX) * projection.scale,
      projection.height - projection.padding - (y - projection.minY) * projection.scale,
    ];
  }

  function unproject(point, projection) {
    const x = finiteNumber(point[0], "canvasX");
    const y = finiteNumber(point[1], "canvasY");
    return [
      projection.minX + (x - projection.padding) / projection.scale,
      projection.minY + (projection.height - projection.padding - y) / projection.scale,
    ];
  }

  function canvasDirectionForCanonicalYaw(yawRadians) {
    const yaw = normalizeRadians(yawRadians);
    return [Math.cos(yaw), -Math.sin(yaw)];
  }

  root.MarketScannerAnchorGeometry = Object.freeze({
    normalizeRadians,
    normalizeDegrees,
    canonicalBounds,
    clampCanonicalPoint,
    createProjection,
    project,
    unproject,
    canvasDirectionForCanonicalYaw,
  });
}(globalThis));
