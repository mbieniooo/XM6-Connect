import Foundation

public enum AmbientSoundMode: String, Sendable {
    case off
    case noiseCancelling
    case ambientSound
}

public struct AmbientSoundState: Equatable, Sendable {
    public var mode: AmbientSoundMode
    public var focusOnVoice: Bool
    /// 0...20, the ambient level. 0x19 reports carry the retained ambient level in every mode.
    public var level: Int

    /// The subtype byte the device itself reported (including 0x19). It is report-only;
    /// ambient writes always use the proven 0x17 form.
    public var subtype: UInt8
    /// Whether the device's report included the extra wind-noise-mode byte
    /// (only seen with subtype 0x17 and an 8-byte payload). This is report-only.
    public var hasWindNoiseByte: Bool

    public init(
        mode: AmbientSoundMode = .noiseCancelling,
        focusOnVoice: Bool = false,
        level: Int = 15,
        subtype: UInt8 = 0x15,
        hasWindNoiseByte: Bool = false
    ) {
        self.mode = mode
        self.focusOnVoice = focusOnVoice
        self.level = max(0, min(20, level))
        self.subtype = subtype
        self.hasWindNoiseByte = hasWindNoiseByte
    }
}
