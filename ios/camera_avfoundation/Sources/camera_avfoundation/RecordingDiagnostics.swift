// Fork(xcc3641): per-recording diagnostics for "recording produced an empty
// file" (CocoCut COCOCUT-5). Pure bookkeeping — nothing here changes what gets
// written. At the end of every take DefaultCamera posts the snapshot as
// `RecordingDiagnostics.notification`; the host app picks it up (no Dart API
// change in this plugin).

import AVFoundation
import Foundation

final class RecordingDiagnostics {
  /// Posted once per take, before the stop completion returns to Dart.
  /// `userInfo` is a plist-compatible `[String: Any]` (see `snapshot`).
  static let notification = Notification.Name("CameraAVFoundationRecordingDiagnostics")

  private let lock = NSLock()
  private var fileName = ""
  private var startedAt = Date()
  private var thermalAtStart = ProcessInfo.ThermalState.nominal

  private var videoSamplesReceived = 0
  private var videoFramesAppended = 0
  private var videoAppendFailed = 0
  private var videoDroppedNotReady = 0
  private var audioSamplesAppended = 0
  private var audioAppendFailed = 0
  private var droppedSessionStopped = 0
  private var droppedWriterFailed = 0
  private var droppedDisconnected = 0
  private var sessionStarted = false
  private var firstVideoPts: Double?
  private var lastVideoPts: Double?

  private var interruptionCount = 0
  private var interruptionReasons: [String] = []
  private var interruptionEndedCount = 0
  private var runtimeErrorCount = 0
  private var runtimeErrorDomain: String?
  private var runtimeErrorCode: Int?

  // Session health, kept across takes: what happened to the capture sessions
  // *between* recordings. Per-take counters above only see the take in flight,
  // which left COCOCUT-5 blind to why the video session was already dead at
  // start. Times are `systemUptime` seconds.
  private var lastInterruptionReason: String?
  private var lastInterruptionAt: TimeInterval?
  private var lastInterruptionEndedAt: TimeInterval?
  private var lastRuntimeErrorDomain: String?
  private var lastRuntimeErrorCode: Int?
  private var lastRuntimeErrorAt: TimeInterval?
  private var lastVideoSampleAt: TimeInterval?
  private var sessionRestartCount = 0
  private var lastRestartReason: String?

  /// Health as it stood when the current take started (see `reset`).
  private var startState: [String: Any] = [:]

  private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

  /// Starts a new take. Freezes the session state at this instant into the
  /// snapshot, so a dead video session can be told apart from one that died
  /// mid-take.
  func reset(
    fileName: String,
    videoSessionRunning: Bool,
    audioSessionRunning: Bool,
    videoSessionInterrupted: Bool
  ) {
    lock.lock()
    defer { lock.unlock() }
    let now = Self.now()
    var state: [String: Any] = [
      "video_session_running_at_start": videoSessionRunning,
      "audio_session_running_at_start": audioSessionRunning,
      "video_session_interrupted_at_start": videoSessionInterrupted,
      "session_restart_count": sessionRestartCount,
    ]
    if let lastVideoSampleAt { state["last_video_sample_age_s"] = now - lastVideoSampleAt }
    if let lastInterruptionReason { state["pre_interruption_reason"] = lastInterruptionReason }
    if let lastInterruptionAt {
      state["pre_interruption_age_s"] = now - lastInterruptionAt
      state["pre_interruption_ended"] = (lastInterruptionEndedAt ?? -1) >= lastInterruptionAt
    }
    if let lastRuntimeErrorAt {
      state["pre_runtime_error_age_s"] = now - lastRuntimeErrorAt
      if let lastRuntimeErrorDomain { state["pre_runtime_error_domain"] = lastRuntimeErrorDomain }
      if let lastRuntimeErrorCode { state["pre_runtime_error_code"] = lastRuntimeErrorCode }
    }
    if let lastRestartReason { state["last_restart_reason"] = lastRestartReason }
    startState = state
    self.fileName = fileName
    startedAt = Date()
    thermalAtStart = ProcessInfo.processInfo.thermalState
    videoSamplesReceived = 0
    videoFramesAppended = 0
    videoAppendFailed = 0
    videoDroppedNotReady = 0
    audioSamplesAppended = 0
    audioAppendFailed = 0
    droppedSessionStopped = 0
    droppedWriterFailed = 0
    droppedDisconnected = 0
    sessionStarted = false
    firstVideoPts = nil
    lastVideoPts = nil
    interruptionCount = 0
    interruptionReasons = []
    interruptionEndedCount = 0
    runtimeErrorCount = 0
    runtimeErrorDomain = nil
    runtimeErrorCode = nil
  }

  private func mutate(_ body: () -> Void) {
    lock.lock()
    body()
    lock.unlock()
  }

  func videoSampleReceived() { mutate { videoSamplesReceived += 1 } }
  /// Every video sample, recording or not.
  func videoSampleSeen() {
    let now = Self.now()
    mutate { lastVideoSampleAt = now }
  }
  func sessionRestarted(reason: String) {
    mutate {
      sessionRestartCount += 1
      lastRestartReason = reason
    }
  }
  func videoDroppedBecauseNotReady() { mutate { videoDroppedNotReady += 1 } }
  func sampleDroppedBecauseSessionStopped() { mutate { droppedSessionStopped += 1 } }
  func sampleDroppedBecauseWriterFailed() { mutate { droppedWriterFailed += 1 } }
  func sampleDroppedBecauseDisconnected() { mutate { droppedDisconnected += 1 } }
  func writerSessionStarted() { mutate { sessionStarted = true } }

  func videoAppend(ok: Bool, at time: CMTime) {
    mutate {
      guard ok else {
        videoAppendFailed += 1
        return
      }
      videoFramesAppended += 1
      let seconds = CMTimeGetSeconds(time)
      if seconds.isFinite {
        if firstVideoPts == nil { firstVideoPts = seconds }
        lastVideoPts = seconds
      }
    }
  }

  func audioAppend(ok: Bool) {
    mutate {
      if ok { audioSamplesAppended += 1 } else { audioAppendFailed += 1 }
    }
  }

  func sessionInterrupted(_ notification: Notification, duringTake: Bool) {
    let reason = Self.interruptionReasonName(notification.userInfo)
    let now = Self.now()
    mutate {
      lastInterruptionReason = reason
      lastInterruptionAt = now
      guard duringTake else { return }
      interruptionCount += 1
      if interruptionReasons.count < 8 { interruptionReasons.append(reason) }
    }
  }

  func sessionInterruptionEnded(duringTake: Bool) {
    let now = Self.now()
    mutate {
      lastInterruptionEndedAt = now
      if duringTake { interruptionEndedCount += 1 }
    }
  }

  func sessionRuntimeError(_ notification: Notification, duringTake: Bool) {
    let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
    let now = Self.now()
    mutate {
      lastRuntimeErrorDomain = error?.domain
      lastRuntimeErrorCode = error?.code
      lastRuntimeErrorAt = now
      guard duringTake else { return }
      runtimeErrorCount += 1
      runtimeErrorDomain = error?.domain
      runtimeErrorCode = error?.code
    }
  }

  /// Plist-compatible dictionary. Keys are snake_case and match the Dart side
  /// (`RecordingDiagnostics.fromWire` in the host app). No file paths: only the
  /// generated file name (`REC_<uuid>.mp4`) so the host can pair it with the
  /// path it got back.
  func snapshot(
    writerStatus: AVAssetWriter.Status?,
    writerError: Error?,
    videoSessionRunning: Bool,
    audioSessionRunning: Bool,
    systemPressure: String?
  ) -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    var info: [String: Any] = [
      "file_name": fileName,
      "writer_status": Self.statusName(writerStatus),
      "writer_session_started": sessionStarted,
      "video_samples_received": videoSamplesReceived,
      "video_frames": videoFramesAppended,
      "video_append_failed": videoAppendFailed,
      "video_dropped_not_ready": videoDroppedNotReady,
      "audio_frames": audioSamplesAppended,
      "audio_append_failed": audioAppendFailed,
      "dropped_session_stopped": droppedSessionStopped,
      "dropped_writer_failed": droppedWriterFailed,
      "dropped_disconnected": droppedDisconnected,
      "interruption_count": interruptionCount,
      "interruption_reasons": interruptionReasons.joined(separator: ","),
      "interruption_ended_count": interruptionEndedCount,
      "runtime_error_count": runtimeErrorCount,
      "video_session_running": videoSessionRunning,
      "audio_session_running": audioSessionRunning,
      "thermal_state": Self.thermalName(ProcessInfo.processInfo.thermalState),
      "thermal_state_at_start": Self.thermalName(thermalAtStart),
      "wall_seconds": Date().timeIntervalSince(startedAt),
    ]
    info.merge(startState) { current, _ in current }
    if let firstVideoPts { info["video_first_pts_s"] = firstVideoPts }
    if let lastVideoPts { info["video_last_pts_s"] = lastVideoPts }
    if let runtimeErrorDomain { info["runtime_error_domain"] = runtimeErrorDomain }
    if let runtimeErrorCode { info["runtime_error_code"] = runtimeErrorCode }
    if let systemPressure { info["system_pressure"] = systemPressure }
    if let error = writerError as NSError? {
      info["writer_error_domain"] = error.domain
      info["writer_error_code"] = error.code
      info["writer_error_desc"] = String(error.localizedDescription.prefix(200))
      if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
        info["writer_underlying_domain"] = underlying.domain
        info["writer_underlying_code"] = underlying.code
      }
    }
    return info
  }

  static func statusName(_ status: AVAssetWriter.Status?) -> String {
    guard let status else { return "none" }
    switch status {
    case .unknown: return "unknown"
    case .writing: return "writing"
    case .completed: return "completed"
    case .failed: return "failed"
    case .cancelled: return "cancelled"
    @unknown default: return "other"
    }
  }

  static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
  }

  static func pressureName(_ level: AVCaptureDevice.SystemPressureState.Level) -> String {
    switch level {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    case .shutdown: return "shutdown"
    default: return "unknown"
    }
  }

  static func interruptionReasonName(_ userInfo: [AnyHashable: Any]?) -> String {
    guard let raw = userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
      let reason = AVCaptureSession.InterruptionReason(rawValue: raw)
    else { return "none" }
    switch reason {
    case .videoDeviceNotAvailableInBackground: return "video_in_background"
    case .audioDeviceInUseByAnotherClient: return "audio_in_use"
    case .videoDeviceInUseByAnotherClient: return "video_in_use"
    case .videoDeviceNotAvailableWithMultipleForegroundApps: return "multiple_foreground_apps"
    case .videoDeviceNotAvailableDueToSystemPressure: return "system_pressure"
    default: return "other_\(raw)"
    }
  }
}
