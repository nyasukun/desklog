import Foundation

/// The real-time audio windowing used by Desklog.
///
/// A new 12-second core is finalized on each cadence. Processing waits for two
/// seconds of following context and retains two seconds before the next core,
/// so adjacent inference windows overlap by four seconds in total:
///
///     first:  [0 ---------------- 14]
///     next:                 [10 ---------------- 26]
///                           2s | 12s core | 2s
///
/// The overlap is removed from text after Whisper returns, while SpeakerKit can
/// use both sides of a boundary to find a natural speaker-change point.
public enum SpeechChunkingPolicy {
    public static let cadenceSeconds: TimeInterval = 12
    public static let boundaryContextSeconds: TimeInterval = 2
    public static let firstFlushDelaySeconds = cadenceSeconds + boundaryContextSeconds
    public static let retainedOverlapSeconds = boundaryContextSeconds * 2
}
