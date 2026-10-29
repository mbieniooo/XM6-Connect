import Foundation

let handshakeQuery: UInt8 = 0x00
let handshakeReply: UInt8 = 0x01
let batteryQuery: UInt8 = 0x22
let batteryReply: UInt8 = 0x23
let batteryEvent: UInt8 = 0x25
let powerParamQuery: UInt8 = 0x26
let powerParamReply: UInt8 = 0x27
let powerParamEvent: UInt8 = 0x29
let eqQuery: UInt8 = 0x56
let eqReply: UInt8 = 0x57
let eqWrite: UInt8 = 0x58
let eqEvent: UInt8 = 0x59
let noiseControlQuery: UInt8 = 0x66
let noiseControlReply: UInt8 = 0x67
let noiseControlWrite: UInt8 = 0x68
let noiseControlEvent: UInt8 = 0x69
let systemParamQuery: UInt8 = 0xf6
let systemParamReply: UInt8 = 0xf7
let systemParamWrite: UInt8 = 0xf8
let systemParamEvent: UInt8 = 0xf9
let systemExtParamQuery: UInt8 = 0xfa
let systemExtParamReply: UInt8 = 0xfb
let systemExtParamEvent: UInt8 = 0xfd

private let audioParamQuery: UInt8 = 0xe6
private let audioParamWrite: UInt8 = 0xe8
private let peripheralQuery: UInt8 = 0x36
private let peripheralWrite: UInt8 = 0x3c

public func strictFlag(_ byte: UInt8) -> Bool? {
    switch byte {
    case 0: return false
    case 1: return true
    default: return nil
    }
}

public enum SonyCommands {
    public static let bandGainRange = -6...6
    public static let defaultBandCount = 10

    public static func buildInit() -> [UInt8] { [handshakeQuery, 0x00] }

    public static func protocolVersion(fromInitReplyPayload payload: [UInt8]) -> ProtocolVersion {
        switch payload.count {
        case 4: return .v1
        case 8: return .v2
        default: return .unknown
        }
    }

    public static func buildAmbientSoundGet(subtype: UInt8) -> [UInt8] {
        [noiseControlQuery, subtype]
    }

    public static func buildAmbientSoundSet(_ state: AmbientSoundState) -> [UInt8] {
        [
            noiseControlWrite,
            0x17,
            0x01,
            state.mode == .off ? 0x00 : 0x01,
            state.mode == .ambientSound ? 0x01 : 0x00,
            state.focusOnVoice ? 0x01 : 0x00,
            UInt8(max(0, min(20, state.level)))
        ]
    }

    public static func decodeAmbientSound(_ payload: [UInt8]) -> AmbientSoundState? {
        guard payload.count >= 7,
              [0x15, 0x17, 0x19, 0x22].contains(payload[1]) else { return nil }
        let subtype = payload[1]
        let focusIndex: Int
        let levelIndex: Int
        let hasWindNoiseByte: Bool
        switch subtype {
        case 0x15, 0x22:
            guard payload.count == 7 else { return nil }
            focusIndex = 5
            levelIndex = 6
            hasWindNoiseByte = false
        case 0x17:
            guard payload.count == 7 || payload.count == 8 else { return nil }
            hasWindNoiseByte = payload.count == 8
            focusIndex = hasWindNoiseByte ? 6 : 5
            levelIndex = hasWindNoiseByte ? 7 : 6
        case 0x19:
            // Opaque bytes may follow the fixed focus/level offsets in this dialect.
            focusIndex = 5
            levelIndex = 6
            hasWindNoiseByte = false
        default:
            return nil
        }
        let enabled: Bool
        if subtype == 0x19 {
            enabled = payload[3] != 0
        } else {
            guard let flag = strictFlag(payload[3]) else { return nil }
            enabled = flag
        }

        guard let focus = strictFlag(payload[focusIndex]), payload[levelIndex] <= 20 else { return nil }

        let mode: AmbientSoundMode
        if !enabled {
            mode = .off
        } else if subtype == 0x22 {
            mode = .ambientSound
        } else if hasWindNoiseByte && (payload[5] == 0x03 || payload[5] == 0x05) {
            mode = .noiseCancelling
        } else {
            mode = payload[4] == 0x01 ? .ambientSound : .noiseCancelling
        }
        return AmbientSoundState(
            mode: mode,
            focusOnVoice: focus,
            level: Int(payload[levelIndex]),
            subtype: subtype,
            hasWindNoiseByte: hasWindNoiseByte
        )
    }

    public static func buildBatteryGet() -> [UInt8] { [batteryQuery, 0x00] }

    public static func decodeBattery(_ payload: [UInt8]) -> BatteryStatus? {
        guard payload.count >= 4, payload[1] == 0x00, payload[2] <= 100 else { return nil }
        return BatteryStatus(level: Int(payload[2]), isCharging: payload[3] == 0x01)
    }

    public static func buildEqualizerGet(subtype: UInt8 = 0x04) -> [UInt8] {
        [eqQuery, subtype]
    }

    /// 0x00 is readable but writes are ignored; XM6 SET frames use 0x04.
    public static func buildEqualizerPresetSet(code: UInt8) -> [UInt8] {
        [eqWrite, 0x04, code, 0x00]
    }

    public static func buildEqualizerBandsSet(bands: [Int]) -> [UInt8] {
        [eqWrite, 0x04, EqualizerPreset.custom.rawValue, UInt8(clamping: bands.count)]
            + bands.map { UInt8(max(-6, min(6, $0)) + 6) }
    }

    public static func decodeEqualizer(_ payload: [UInt8]) -> EqualizerState? {
        guard payload.count >= 4, [0x00, 0x02, 0x04].contains(payload[1]),
              [0, 6, 10].contains(Int(payload[3])) else { return nil }
        let count = Int(payload[3])
        guard payload.count >= 4 + count else { return nil }
        let bias = count == 6 ? 10 : 6
        let bands = payload[4..<(4 + count)].map { Int($0) - bias }
        guard bands.allSatisfy({ bandGainRange.contains($0) }) else { return nil }
        return EqualizerState(presetCode: payload[2], bands: bands, subtype: payload[1])
    }

    public static func buildBGMModeGet(subtype: UInt8 = 0x09) -> [UInt8] {
        [audioParamQuery, subtype]
    }

    public static func buildBGMModeSet(enabled: Bool, roomSize: BGMRoomSize, subtype: UInt8 = 0x09) -> [UInt8] {
        [audioParamWrite, subtype, enabled ? 0x00 : 0x01, roomSize.rawValue]
    }

    public static func decodeBGMMode(_ payload: [UInt8]) -> (enabled: Bool, roomSize: BGMRoomSize)? {
        guard payload.count >= 4, payload[1] == 0x09,
              let roomSize = BGMRoomSize(rawValue: payload[3]) else { return nil }
        return (payload[2] == 0x00, roomSize)
    }

    public static func buildUpmixCinemaGet() -> [UInt8] { [audioParamQuery, 0x04] }

    public static func buildUpmixCinemaSet(enabled: Bool) -> [UInt8] {
        [audioParamWrite, 0x04, enabled ? 0x00 : 0x01]
    }

    public static func decodeUpmixCinema(_ payload: [UInt8]) -> Bool? {
        guard payload.count >= 3, payload[1] == 0x04 else { return nil }
        return payload[2] == 0x00
    }

    public static func buildDeviceListGet() -> [UInt8] { [peripheralQuery, 0x02] }

    public static func buildSourceSwitchSet(macAddress: String) -> [UInt8]? {
        let mac = Array(macAddress.utf8)
        guard mac.count == 17 else { return nil }
        return [peripheralWrite, 0x01] + mac
    }

    public static func decodeDeviceList(_ payload: [UInt8]) -> [MultipointDevice]? {
        guard payload.count >= 4, [0x00, 0x02].contains(payload[1]) else { return nil }
        let subtype = payload[1]
        let count = Int(payload[2])
        guard count < 16 else { return nil }
        if count == 0 { return payload.count == 4 ? [] : nil }

        var index = 3
        var devices: [MultipointDevice] = []
        for _ in 0..<count {
            let classLength = subtype == 0x02 ? 3 : 0
            guard index + 17 + 1 + classLength + 1 <= payload.count else { return nil }
            let macBytes = payload[index..<(index + 17)]
            guard let macAddress = String(bytes: macBytes, encoding: .utf8) else { return nil }
            index += 17
            let connectedStatus = payload[index]
            index += 1 + classLength
            let nameLength = Int(payload[index])
            index += 1
            guard index + nameLength <= payload.count else { return nil }
            let name = String(bytes: payload[index..<(index + nameLength)], encoding: .utf8) ?? "Unknown device"
            index += nameLength
            devices.append(MultipointDevice(macAddress: macAddress, name: name, connectedStatus: connectedStatus, isPlayback: false))
        }
        guard index + 1 == payload.count else { return nil }
        let playbackStatus = payload[index]
        return devices.map { device in
            var device = device
            device.isPlayback = device.connectedStatus != 0 && device.connectedStatus == playbackStatus
            return device
        }
    }

    public static func buildSpeakToChatEnabledGet() -> [UInt8] { [systemParamQuery, 0x0c] }

    public static func buildSpeakToChatEnabledSet(_ enabled: Bool) -> [UInt8] {
        [systemParamWrite, 0x0c, enabled ? 0x00 : 0x01, 0x01]
    }

    public static func decodeSpeakToChatEnabled(_ payload: [UInt8]) -> Bool? {
        guard payload.count == 4, payload[1] == 0x0c else { return nil }
        switch payload[2] {
        case 0x00: return true
        case 0x01: return false
        default: return nil
        }
    }

    public static func buildSpeakToChatConfigGet() -> [UInt8] { [systemExtParamQuery, 0x0c] }

    public static func decodeSpeakToChatConfig(_ payload: [UInt8]) -> SpeakToChatConfigState? {
        guard payload.count == 4, payload[1] == 0x0c,
              let sensitivity = SpeakToChatSensitivity(rawValue: payload[2]),
              let timeout = SpeakToChatTimeout(rawValue: payload[3]) else { return nil }
        return SpeakToChatConfigState(sensitivity: sensitivity, timeout: timeout)
    }

    public static func buildAutomaticPowerOffGet() -> [UInt8] { [powerParamQuery, 0x05] }

    public static func decodeAutomaticPowerOff(_ payload: [UInt8]) -> AutomaticPowerOffMode? {
        guard payload.count == 4, payload[1] == 0x05 else { return nil }
        return AutomaticPowerOffMode(rawValue: payload[2])
    }

    public static func buildPauseWhenTakenOffGet() -> [UInt8] { [systemParamQuery, 0x01] }

    public static func decodePauseWhenTakenOff(_ payload: [UInt8]) -> Bool? {
        guard payload.count == 3, payload[1] == 0x01 else { return nil }
        switch payload[2] {
        case 0x00: return true
        case 0x01: return false
        default: return nil
        }
    }
}
