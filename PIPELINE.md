# 3D Gaussian Splat Pipeline — Plan & Data Reference

Companion doc for the desktop half of this project. The app (this repo) is Stage 0:
it captures the data. Everything below runs on the desktop (RTX 3080).

## Session folder contents (exported as zip from the app)

| File | Contents |
|---|---|
| `video.mov` | Primary footage (HEVC). 1x mode: wide camera. 0.5x mode: ultrawide. |
| `wide.mov` | 0.5x mode only: 640x480 wide (1x) reference video, pixel-registered to the depth maps. |
| `depth/depth_NNNNNN_TTTT.bin` | Raw depth, float32 meters, 320x240, row stride 1280 bytes. `TTTT` = timestamp in microseconds. |
| `depth/depth_NNNNNN_TTTT.json` | Per-frame: intrinsics (fx, fy, cx, cy for 640x480 reference), accuracy/quality flags, pixel size. Registered to the WIDE camera always. |
| `frames.csv` | Per primary-video-frame: timestampMicros, lensPosition, fx, fy, cx, cy (intrinsics of the primary camera, matching delivered orientation). |
| `motion.csv` | 100Hz IMU: timestampMicros, gyro xyz (rad/s, bias-corrected), userAcceleration xyz (g), gravity xyz (g), attitude quaternion wxyz. |
| `drops.csv` | Any dropped frames: stream (video/wide/depth), timestampMicros. Empty = clean capture. |
| `manifest.json` | Settings used, frame counts, costs, and in 0.5x mode `wideToUltrawideExtrinsics`. |

**Clocks:** every timestampMicros in every file shares the device boot-time host
clock. Pair streams by nearest timestamp; no conversion needed.

**Extrinsics (0.5x manifest):** `wideToUltrawideExtrinsics` = 16 floats, 4 columns x 4
values with simd padding (every 4th value is padding, ignore it). Columns 1-3 =
rotation columns, column 4 = translation in **millimeters**, wide camera -> ultrawide camera.

**Depth caveats:** depth covers the wide lens FOV (~70°) only — in 0.5x mode that is
the central portion of the ultrawide frame. Depth is unfiltered/raw (holes are real).
No per-pixel confidence exists (that is ARKit-only); use the per-frame quality flag.

## Pipeline stages (agreed plan)

1. **Stage 1 — preprocessing** (Python + OpenCV/NumPy/ffmpeg, CPU):
   - Extract frames from video.mov (and wide.mov in 0.5x sessions), named by timestamp via frames.csv ordering.
   - Pair depth .bin files to wide frames by nearest timestamp; convert to 16-bit millimeter PNGs (or .npy).
   - Trim first/last ~1s (record/stop tap contamination in both video and IMU).
   - Blur-score (Laplacian variance) subsampling: all frames for SfM, sharpest ~2-4 fps for splat training.
   - Undistortion: likely unnecessary (iOS applies geometric distortion correction by default) — verify once on a doorframe shot.
2. **Stage 2 — poses (plan A)**: COLMAP or GLOMAP offline SfM. In 0.5x sessions use
   wide+ultrawide frames as a camera rig with the manifest extrinsics fixed. Then fit
   one global scale factor: SfM depth vs LiDAR depth (robust least squares).
   **Plan B (fallback if SfM fails on featureless areas):** SplaTAM on the wide RGB-D
   stream, transfer poses to ultrawide via extrinsics. VIGS-SLAM deprioritized (immature code).
3. **Stage 3 — splat training**: initialize gaussians from LiDAR depth back-projected
   through recovered poses (dense + metric, covers blank walls where SfM has no points).
   Train with depth supervision (gsplat, or LichtFeld Studio if it supports a depth loss).
   Use IMU gravity vector to level the final model.

**First end-to-end run: use a 1x capture** (depth registered to the same 4K camera —
no extrinsics transfer, fewest moving parts). Graduate to 0.5x afterward.

## Capture guidance

- Indoor preset (1/250, ISO 640) or Outdoor (1/500, ISO 100); lock exposure + WB (no AUTO) for photometric consistency.
- Stabilization OFF for all scan captures (it warps frames).
- Medium deliberate walking pace; keep geometry-rich areas in frame; overlap the path and end where you started.
- Check drops.csv is empty and thermal stayed nominal (debug_log.txt) after long captures.
