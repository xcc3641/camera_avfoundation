# camera\_avfoundation

The iOS implementation of [`camera`][1].

## Usage

This package is [endorsed][2], which means you can simply use `camera`
normally. This package will be automatically included in your app when you do,
so you do not need to add it to your `pubspec.yaml`.

However, if you `import` this package to use any of its APIs directly, you
should add it to your `pubspec.yaml` as usual.

[1]: https://pub.dev/packages/camera
[2]: https://flutter.dev/to/endorsed-federated-plugin

## Fork notes (xcc3641)

Patched copy of `camera_avfoundation` used by CocoCut (flutter_yige).

**Why:** upstream routes both the Flutter preview texture and the recording
sample buffers through one `AVCaptureVideoDataOutput`, and
`lockCaptureOrientation` rotates that shared connection's pixels. Hold the
phone landscape and press record: the preview flips 90° for the whole
recording, then snaps back on stop. The file is correct; the preview is not.

**The patch** (`ios/.../DefaultCamera.swift`, plus one protocol property):

1. `updateOrientation` pins the video output's connection to portrait, so the
   preview never rotates — recording or not. The photo output still follows
   the locked/device orientation as before.
2. `setupWriter` expresses the recording orientation as
   `AVAssetWriterInput.transform` — the same rotation the connection would
   have applied, carried as track metadata. Players and ffmpeg's autorotate
   honor it (verified against the app's two-phase export: autorotate applies
   inside `-filter_complex [0:v]`, segments stay `-c copy`-joinable, sticker
   overlays land on the rotated-upright frame).
3. `AssetWriterInput` (test seam protocol) gains a `transform` passthrough;
   `AVAssetWriterInput` satisfies it for free, the mock stores it.

Landscape sign mapping (`videoTransform(forDeviceOrientation:)`) was derived,
not measured — if landscape recordings come out upside-down on device, swap
the `.landscapeLeft` / `.landscapeRight` cases.
