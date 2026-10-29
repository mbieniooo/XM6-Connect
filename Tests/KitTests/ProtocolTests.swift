import Foundation
import SonyHeadphonesKit
import XM6ConnectWidgetLogic

func testCodecRoundTripEscapedPayload() -> Bool {
    let message = SonyMessage(type: .primary, sequenceNumber: 1, payload: [0x3e, 0x3c, 0x3d, 0x00])
    return SonyMessage.decode(rawFrame: message.encode()) == message
}

func testSonyMessageGoldenEncoding() -> Bool {
    SonyMessage(type: .primary, sequenceNumber: 0, payload: [0x00, 0x00]).encode()
        == [0x3e, 0x0c, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x0e, 0x3c]
}

func testCodecRejectsChecksumFailure() -> Bool {
    var frame = SonyMessage(type: .primary, sequenceNumber: 0, payload: [0x01]).encode()
    frame[frame.count - 2] ^= 0x01
    return SonyMessage.decode(rawFrame: frame) == nil
}

func testCodecRejectsLengthMismatch() -> Bool {
    let body: [UInt8] = [SonyMessageType.primary.rawValue, 0, 0, 0, 0, 2]
    let frame = [SonyMessage.frameStart] + body + [SonyMessage.checksum(body), SonyMessage.frameEnd]
    return SonyMessage.decode(rawFrame: frame) == nil
}

func testCodecRejectsMinimumSizeViolation() -> Bool {
    SonyMessage.decode(rawFrame: [SonyMessage.frameStart, SonyMessage.frameEnd]) == nil
}

func testFragmentedByteAtATimeDelivery() -> Bool {
    let expected = SonyMessage(type: .primary, sequenceNumber: 0, payload: [0x23, 0, 61, 0])
    let parser = FrameParser()
    var actual: [SonyMessage] = []
    for byte in expected.encode() {
        actual += parser.feed([byte])
    }
    return actual == [expected]
}

func testGarbagePrefixIsDiscarded() -> Bool {
    let expected = SonyMessage(type: .secondary, sequenceNumber: 1, payload: [1, 2, 3])
    return FrameParser().feed([0, 0xff, 0x3d] + expected.encode()) == [expected]
}

func testTruncatedFrameThenValidFrameResynchronizesAtInnerHeader() -> Bool {
    let valid = SonyMessage(type: .primary, sequenceNumber: 1, payload: [0x57, 0x04, 0x20])
    let truncated: [UInt8] = [SonyMessage.frameStart, SonyMessageType.primary.rawValue, 0, 0, 0]
    return FrameParser().feed(truncated + valid.encode()) == [valid]
}

func testBufferCapDropsUnterminatedGarbage() -> Bool {
    let parser = FrameParser()
    _ = parser.feed([SonyMessage.frameStart] + Array(repeating: 0, count: 8192))
    return parser.bufferedByteCount == 0
}

func testBatteryLiveVector() -> Bool {
    guard let battery = SonyCommands.decodeBattery([0x23, 0x00, 0x3d, 0x00]) else { return false }
    return battery == BatteryStatus(level: 61, isCharging: false)
}

func testAmbient17LiveVector() -> Bool {
    // This layout decoder intentionally accepts the constant reply; the dispatcher drops it.
    guard let ambient = SonyCommands.decodeAmbientSound([0x67, 0x17, 0, 0, 0, 0, 0]) else { return false }
    return ambient.mode == .off && ambient.level == 0 && ambient.subtype == 0x17
}

func testAmbient19ObservedNotifyVector() -> Bool {
    guard let ambient = SonyCommands.decodeAmbientSound([0x69, 0x19, 0x01, 0x01, 0x00, 0x00, 0x14, 0x00, 0x00]) else { return false }
    return ambient.mode == .noiseCancelling
        && ambient.level == 20
        && ambient.subtype == 0x19
        && SonyCommands.buildAmbientSoundSet(ambient) == [0x68, 0x17, 0x01, 0x01, 0x00, 0x00, 0x14]
}

func testWindByteIsNeverWritten() -> Bool {
    let state = AmbientSoundState(mode: .ambientSound, focusOnVoice: false, level: 12, subtype: 0x17, hasWindNoiseByte: true)
    let payload = SonyCommands.buildAmbientSoundSet(state)
    if payload != [0x68, 0x17, 0x01, 0x01, 0x01, 0x00, 0x0c] {
        let observed = payload.map { String(format: "%02x", $0) }.joined(separator: " ")
        print("  diagnostic testWindByteIsNeverWritten observed \(observed)")
        return false
    }
    return true
}

func testGamePresetCapturedVector() -> Bool {
    // The Sony app's "Game" preset makes the headset report preset 0x20.
    guard EqualizerPreset(rawValue: 0x20) == .game, EqualizerPreset.game.label == "Game" else { return false }
    // Reply layout: [opcode, subtype 0x04, preset, bandCount, bands+6...]
    let payload: [UInt8] = [0x57, 0x04, 0x20, 0x0a, 0x00, 0x04, 0x08, 0x09, 0x07, 0x05, 0x07, 0x09, 0x06, 0x04]
    guard let eq = SonyCommands.decodeEqualizer(payload) else { return false }
    return eq.presetCode == 0x20 && eq.preset == .game && eq.bands.count == 10
}

func testEqualizerLiveVector() -> Bool {
    guard let equalizer = SonyCommands.decodeEqualizer([0x57, 0x04, 0x20, 0x0a, 0x00, 0x04, 0x08, 0x09, 0x07, 0x05, 0x07, 0x09, 0x06, 0x04]) else { return false }
    return equalizer.presetCode == 0x20
        && equalizer.subtype == 0x04
        && equalizer.bands == [-6, -2, 2, 3, 1, -1, 1, 3, 0, -2]
}

func testMultipointListWithASCIIMACEntries() -> Bool {
    var payload: [UInt8] = [0x00, 0x02, 0x02]
    payload += Array("AA:BB:CC:DD:EE:FF".utf8) + [0x01, 0, 0, 0, 5] + Array("Phone".utf8)
    payload += Array("11:22:33:44:55:66".utf8) + [0x02, 0, 0, 0, 3] + Array("Mac".utf8)
    payload += [0x02]

    guard let devices = SonyCommands.decodeDeviceList(payload) else { return false }
    return devices.map(\.macAddress) == ["AA:BB:CC:DD:EE:FF", "11:22:33:44:55:66"]
        && devices.map(\.name) == ["Phone", "Mac"]
        && devices.map(\.isPlayback) == [false, true]
}

func testInvertedOnOffFlagsDecodeAsEnabledOnZero() -> Bool {
    // Speak-to-chat and pause-when-taken-off report 00 for enabled and 01 for disabled;
    // any other value is rejected.
    SonyCommands.decodeSpeakToChatEnabled([0xf7, 0x0c, 0x00, 0x01]) == true
        && SonyCommands.decodeSpeakToChatEnabled([0xf7, 0x0c, 0x01, 0x01]) == false
        && SonyCommands.decodeSpeakToChatEnabled([0xf7, 0x0c, 0x02, 0x01]) == nil
        && SonyCommands.decodePauseWhenTakenOff([0xf7, 0x01, 0x00]) == true
        && SonyCommands.decodePauseWhenTakenOff([0xf7, 0x01, 0x01]) == false
        && SonyCommands.decodePauseWhenTakenOff([0xf7, 0x01, 0x02]) == nil
}

func testAmbientLevelAboveTwentyIsRejected() -> Bool {
    // Level is 0...20; focus and level are the last two bytes of a 15/17/22 report.
    SonyCommands.decodeAmbientSound([0x67, 0x17, 0x00, 0x01, 0x00, 0x00, 0x14]) != nil
        && SonyCommands.decodeAmbientSound([0x67, 0x17, 0x00, 0x01, 0x00, 0x00, 0x15]) == nil
}

func testUnknownEscapePairIsRejected() -> Bool {
    // Only 3D 2C / 2D / 2E are escapes. A frame whose checksum would be right if 3D 41 were
    // read as 0x51 must still be rejected, so a lenient unescape cannot slip through.
    let body: [UInt8] = [0x0c, 0x00, 0x00, 0x00, 0x00, 0x01, 0x51]
    let frame: [UInt8] = [SonyMessage.frameStart, 0x0c, 0x00, 0x00, 0x00, 0x00, 0x01, 0x3d, 0x41,
                          SonyMessage.checksum(body), SonyMessage.frameEnd]
    return SonyMessage.decode(rawFrame: frame) == nil
}

func testAmbientRejectsUnknownLayoutsAndOnOffValues() -> Bool {
    // 15, 22 and 17 without its noise-mode byte are seven bytes; 17 with it is eight. Any other
    // length is an unknown layout, and the on/off byte of these dialects is 00 or 01 only.
    let decode = SonyCommands.decodeAmbientSound
    return decode([0x67, 0x15, 0x00, 0x01, 0x01, 0x00, 0x0a]) != nil
        && decode([0x67, 0x15, 0x00, 0x01, 0x01, 0x00, 0x0a, 0x00]) == nil
        && decode([0x67, 0x22, 0x00, 0x01, 0x01, 0x00, 0x0a, 0x00]) == nil
        && decode([0x67, 0x17, 0x00, 0x01, 0x01, 0x02, 0x00, 0x0a])?.hasWindNoiseByte == true
        && decode([0x67, 0x17, 0x00, 0x01, 0x01, 0x02, 0x00, 0x0a, 0x00]) == nil
        && decode([0x67, 0x17, 0x00, 0x02, 0x01, 0x00, 0x0a]) == nil
}

func testStrictProtocolAndWidgetBounds() -> Bool {
    let invalidEQCount = SonyCommands.decodeEqualizer([0x57, 0x04, 0x20, 0x07, 0,0,0,0,0,0,0]) == nil
    let invalidEQGain = SonyCommands.decodeEqualizer([0x57, 0x04, 0x20, 0x0a, 13,6,6,6,6,6,6,6,6,6]) == nil
    let invalidBattery = SonyCommands.decodeBattery([0x23, 0x00, 101, 0]) == nil
    let emptyDevices = SonyCommands.decodeDeviceList([0, 2, 0, 0]) == []
    let unknownDevices = SonyCommands.decodeDeviceList([0, 2, 16, 0]) == nil
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xm6connect-large-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let tooLarge = directory.appendingPathComponent("state.json")
    try? Data(repeating: 0, count: XM6ConnectStateReader.maximumStateFileBytes + 1).write(to: tooLarge)
    return invalidEQCount && invalidEQGain && invalidBattery && emptyDevices && unknownDevices
        && XM6ConnectStateReader.readViewModel(from: tooLarge) == .unavailable
}

func testBGMDecodesTypeNineOnly() -> Bool {
    let kitType3 = SonyCommands.decodeBGMMode([0xe7, 0x03, 0x00, 0x01])
    let replyType3 = SonyEventDecoder.decode(payload: [0xe7, 0x03, 0x00, 0x01], messageType: .primary)
    let eventType3 = SonyEventDecoder.decode(payload: [0xe9, 0x03, 0x00, 0x01], messageType: .primary)
    let kitType9 = SonyCommands.decodeBGMMode([0xe7, 0x09, 0x00, 0x01])
    let kitType9Off = SonyCommands.decodeBGMMode([0xe7, 0x09, 0x01, 0x02])
    var replyType9OK = false, eventType9OK = false
    if case .bgmMode(let enabled, let roomSize)? = SonyEventDecoder.decode(payload: [0xe7, 0x09, 0x00, 0x01], messageType: .primary) {
        replyType9OK = enabled && roomSize == .middle
    }
    if case .bgmMode(let enabled, let roomSize)? = SonyEventDecoder.decode(payload: [0xe9, 0x09, 0x01, 0x02], messageType: .primary) {
        eventType9OK = !enabled && roomSize == .large
    }
    var problems: [String] = []
    if kitType3 != nil { problems.append("decodeBGMMode accepts e7 03") }
    if replyType3 != nil { problems.append("decoder accepts e7 03") }
    if eventType3 != nil { problems.append("decoder accepts e9 03") }
    if !(kitType9?.enabled == true && kitType9?.roomSize == .middle) { problems.append("decodeBGMMode e7 09 00 01 lost") }
    if !(kitType9Off?.enabled == false && kitType9Off?.roomSize == .large) { problems.append("decodeBGMMode e7 09 01 02 lost") }
    if !replyType9OK { problems.append("decoder e7 09 00 01 lost") }
    if !eventType9OK { problems.append("decoder e9 09 01 02 lost") }
    if !problems.isEmpty { print("    BGM type decode: " + problems.joined(separator: "; ")) }
    return problems.isEmpty
}

func testAmbientWriteBytesFollowModeAndFocus() -> Bool {
    // Bytes 3-6 of every write carry on/off, Ambient-or-NC, focus and level.
    let build = { (mode: AmbientSoundMode, focus: Bool, level: Int) in
        SonyCommands.buildAmbientSoundSet(AmbientSoundState(mode: mode, focusOnVoice: focus, level: level, subtype: 0x19, hasWindNoiseByte: false))
    }
    let off = build(.off, true, 13), ambient = build(.ambientSound, false, 8), nc = build(.noiseCancelling, true, 20)
    guard off == [0x68, 0x17, 0x01, 0x00, 0x00, 0x01, 0x0d], ambient == [0x68, 0x17, 0x01, 0x01, 0x01, 0x00, 0x08],
          nc == [0x68, 0x17, 0x01, 0x01, 0x00, 0x01, 0x14] else {
        print("    write bytes off=\(hexBytes(off)) ambient=\(hexBytes(ambient)) nc=\(hexBytes(nc))"); return false
    }
    return true
}

func testAmbientWriteIgnoresEveryReportedDialect() -> Bool {
    // Whatever dialect a state was reported in, with or without the wind byte, the write is the
    // proven 7-byte 68 17 form.
    for subtype: UInt8 in [0x15, 0x17, 0x19, 0x22] {
        for wind in [false, true] {
            let write = SonyCommands.buildAmbientSoundSet(AmbientSoundState(mode: .noiseCancelling, focusOnVoice: false, level: 20, subtype: subtype, hasWindNoiseByte: wind))
            guard write == [0x68, 0x17, 0x01, 0x01, 0x00, 0x00, 0x14] else { print("    dialect \(subtype) wind \(wind): \(hexBytes(write))"); return false }
        }
    }
    return true
}

func testAmbient17EventsStillDecode() -> Bool {
    // Only the 67 17 reply is the constant. A 69 17 event still decodes, so the filter keys on
    // the reply opcode.
    guard case .ambientSound(let state)? = SonyEventDecoder.decode(payload: [0x69, 0x17, 0x00, 0x01, 0x01, 0x00, 0x08], messageType: .primary),
          state.mode == .ambientSound, state.level == 8 else { print("    69 17 event not decoded"); return false }
    return true
}
