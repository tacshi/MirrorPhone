@preconcurrency import AVFoundation
import CoreImage
import Foundation

struct MirrorVideoSample: @unchecked Sendable {
  let image: CIImage
  let presentationTime: CMTime
}

struct MirrorAudioHostClockAnchor: Sendable {
  let timelineID: UUID
  let bufferEndTime: CMTime
}

struct MirrorAudioSample: @unchecked Sendable {
  let sampleBuffer: CMSampleBuffer
  /// Android audio is counted on the device's 48 kHz sample clock while its
  /// video is timestamped on the Mac host clock. This anchor lets each
  /// recording map the current helper timeline onto that shared host clock.
  /// AVCapture audio is already on the video timeline and leaves this nil.
  let hostClockAnchor: MirrorAudioHostClockAnchor?

  init(
    sampleBuffer: CMSampleBuffer,
    hostClockAnchor: MirrorAudioHostClockAnchor? = nil
  ) {
    self.sampleBuffer = sampleBuffer
    self.hostClockAnchor = hostClockAnchor
  }
}

enum MirrorRecordingAudioState: Equatable, Sendable {
  case pending
  case available
  case unavailable(String)
}

protocol MirrorRecordingSink: AnyObject, Sendable {
  func receive(video sample: MirrorVideoSample)
  func receive(audio sample: MirrorAudioSample)
  func audioStateChanged(_ state: MirrorRecordingAudioState)
}

/// A capture-side, weak recording hand-off. Sink methods only enqueue work and
/// return; the short lock also makes detach a barrier for in-flight emissions,
/// without adding file I/O or encoder backpressure to live mirroring.
final class MirrorRecordingTap: @unchecked Sendable {
  private let lock = NSLock()
  private weak var sink: (any MirrorRecordingSink)?
  private var audioState = MirrorRecordingAudioState.pending

  func attach(_ sink: any MirrorRecordingSink) {
    let state = lock.withLock {
      self.sink = sink
      return audioState
    }
    sink.audioStateChanged(state)
  }

  func detach(_ expectedSink: (any MirrorRecordingSink)? = nil) {
    lock.withLock {
      guard expectedSink == nil || sink === expectedSink else { return }
      sink = nil
    }
  }

  func emit(video sample: MirrorVideoSample) {
    lock.withLock {
      sink?.receive(video: sample)
    }
  }

  func emit(audio sample: MirrorAudioSample) {
    lock.withLock {
      sink?.receive(audio: sample)
    }
  }

  func setAudioState(_ state: MirrorRecordingAudioState) {
    let target = lock.withLock {
      guard audioState != state else { return nil as (any MirrorRecordingSink)? }
      audioState = state
      return sink
    }
    target?.audioStateChanged(state)
  }
}
