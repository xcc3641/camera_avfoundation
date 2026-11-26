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
4. `setFocusPoint` / `setExposurePoint` read the point as portrait. Upstream
   rotates it by the physical device orientation, which only makes sense
   when the preview rotates too; with the connection pinned, a landscape tap
   would focus and meter somewhere else in the frame.

Landscape sign mapping (`videoTransform(forDeviceOrientation:)`) was derived,
not measured — if landscape recordings come out upside-down on device, swap
the `.landscapeLeft` / `.landscapeRight` cases.

**Recording diagnostics** (`RecordingDiagnostics.swift`): diagnostics only, no
behavior change. Each take counts samples received / appended / dropped (and
why), first/last video PTS, session interruptions (with reason), runtime
errors and thermal state. On stop the snapshot is posted as
`CameraAVFoundationRecordingDiagnostics` (`userInfo` = plist dictionary, keys
snake_case) right before the result returns; CocoCut's Runner forwards it to
Dart for "empty file" reports.

**Refuse takes on a dead video source** (`DefaultCamera.swift`,
`RecordingDiagnostics.swift`, `CaptureSession.isInterrupted`): CocoCut
COCOCUT-5 showed takes where the video capture session was not running for the
whole recording — audio kept arriving, not one video sample did, the writer
never started its session and `finishWriting` "completed" a 0-byte file.

1. `startVideoRecording` checks the video source before opening a writer: if
   the video session is interrupted, not running (after one synchronous
   `startRunning` retry), or the video data output's connection is disabled /
   inactive, the call fails with `PigeonError(code:
   "CameraVideoSourceUnavailable", message: <reason>)` — reason is
   `video_session_interrupted` / `video_session_not_running` /
   `video_connection_inactive`. No file is created. The `camera` package keeps
   only code + message, so the reason rides in the message.
2. Capture sessions are restarted when the system stopped them behind our back:
   on `interruptionEnded` and on a `mediaServicesWereReset` runtime error, any
   session that is neither running nor interrupted gets `startRunning()` on the
   session queue — only between `start()` and `stop()`, never after `close()`.
3. Diagnostics no longer ignore what happens between takes: the last
   interruption (reason, age, ended or not), the last runtime error, the age of
   the last video sample, and the restart count are kept across takes and
   frozen into the snapshot at record start, alongside
   `video_session_running_at_start` / `audio_session_running_at_start` /
   `video_session_interrupted_at_start`. A refused start posts the diagnostics
   notification too, with `start_rejected = <reason>` and no writer fields.
