import Foundation

public enum SpeakToChatSensitivity: UInt8, Sendable {
    case auto = 0x00
    case high = 0x01
    case low = 0x02

}

public enum SpeakToChatTimeout: UInt8, Sendable {
    case short = 0x00
    case standard = 0x01
    case long = 0x02
    case off = 0x03

}

public struct SpeakToChatConfigState: Equatable, Sendable {
    public var sensitivity: SpeakToChatSensitivity
    public var timeout: SpeakToChatTimeout

    public init(sensitivity: SpeakToChatSensitivity, timeout: SpeakToChatTimeout) {
        self.sensitivity = sensitivity
        self.timeout = timeout
    }
}
