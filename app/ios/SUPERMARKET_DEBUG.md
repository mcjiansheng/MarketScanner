# Supermarket iPhone Pro First-Version Debug Flow

This first version adds supermarket-oriented segment rollover and NFC price-tag recording to the existing iOS RTAB-Map app.

## Build Setup

1. Open `app/ios/RTABMapApp.xcodeproj` in Xcode on macOS.
2. Select the `RTABMapApp` target.
3. Use a physical iPhone Pro device. ARKit + LiDAR + NFC cannot be fully tested in Simulator.
4. In Signing & Capabilities, confirm:
   - Increased Memory Limit is enabled if your Apple account/profile supports it.
   - Near Field Communication Tag Reading is enabled.
5. Confirm `Info.plist` contains `NFCReaderUsageDescription`.
6. Build and run on device.

## First Scan Test

1. Start a new mapping session.
2. Press Record.
3. Walk a small loop in a feature-rich area.
4. Confirm the HUD shows:
   - `Scanned Area`
   - `Segment`
   - RAM usage
5. Open the menu and choose `Save Current Segment`.
6. Expected result:
   - Mapping pauses briefly.
   - A segment is saved.
   - Mapping resumes automatically with the next segment number.

Saved files are written under:

```text
Documents/SupermarketSession-YYYYMMDD-HHMMSS/segment_0001/
  rtabmap_segment_0001.db
  metadata.json
  price_tags.json
  price_tags.csv
```

The app has `UIFileSharingEnabled`, so the folder can be inspected through Finder device files or the Files app.

## NFC Price Tag Test

1. While mapping, open the menu.
2. Choose `Read Price Tag NFC`.
3. Hold the iPhone near an NDEF price tag.
4. Expected result:
   - A toast confirms the tag was recorded.
   - The current pose and node count are appended to `price_tags.json` and `price_tags.csv` when the segment is saved.

Each record contains:

```text
tagIdentifier,payload,timestamp,segmentIndex,nodeCount,x,y,z,roll,pitch,yaw
```

## Automatic Segment Rollover

The first version rolls over a segment when any condition is met:

- estimated scanned floor area >= `250 m2`
- RTAB-Map database memory >= `900 MB`
- app used memory >= `2500 MB`

These defaults are in `SupermarketScanSession`.

The area estimate is a trajectory-swept floor estimate using the horizontal `x/z` pose plane. It is intentionally conservative for the first version and should later be replaced or calibrated against a true occupancy-grid export if needed.

## Tuning Checklist

For a real supermarket pilot:

1. Start with `areaThresholdM2 = 150...250`.
2. Keep LiDAR mode enabled.
3. Walk aisles twice in opposite directions for loop closures.
4. Read each NFC tag from a consistent distance and orientation.
5. Export after each aisle group manually during early tests.
6. Inspect segment CSV/JSON and confirm tag poses line up with the visual map.

## Known First-Version Limits

- Segment rollover pauses briefly while saving.
- Segments are independent RTAB-Map databases; cross-segment merge is a later step.
- The clean 2D supermarket UI is represented first by HUD area/segment state; a dedicated floor-plan view should be added after the data flow is validated.
- NFC records are sidecar CSV/JSON files, not yet embedded in the RTAB-Map SQLite schema.
