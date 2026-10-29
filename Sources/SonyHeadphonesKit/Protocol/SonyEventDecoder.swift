import Foundation

public enum HeadphonesEvent: Sendable {
    case protocolInfo(ProtocolVersion)
    case ambientSound(AmbientSoundState)
    case battery(BatteryStatus)
    case speakToChatEnabled(Bool)
    case speakToChatConfig(SpeakToChatConfigState)
    case automaticPowerOff(AutomaticPowerOffMode)
    case pauseWhenTakenOff(Bool)
    case equalizer(EqualizerState)
    case bgmMode(enabled: Bool, roomSize: BGMRoomSize)
    case upmixCinema(Bool)
    case deviceList([MultipointDevice])
}

public enum SonyEventDecoder {
    private static let audioParameterReplyOpcode: UInt8 = 0xe7
    private static let audioParameterEventOpcode: UInt8 = 0xe9
    private static let peripheralReplyOpcode: UInt8 = 0x37
    private static let peripheralEventOpcode: UInt8 = 0x39

    public static func decode(payload: [UInt8], messageType: SonyMessageType) -> HeadphonesEvent? {
        guard let opcode = payload.first else { return nil }

        switch messageType {
        case .primary:
            if opcode == handshakeReply {
                return .protocolInfo(SonyCommands.protocolVersion(fromInitReplyPayload: payload))
            }
            guard payload.count > 1 else { return nil }
            // The XM6 answers the 0x17 query with a constant reply that carries no ambient state.
            // Filter on opcode before payload decoding so 0x69/0x17 events remain supported.
            if opcode == noiseControlReply && payload[1] == 0x17 { return nil }
            switch (opcode, payload[1]) {
            case (noiseControlReply, 0x15),
                 (noiseControlReply, 0x19), (noiseControlReply, 0x22),
                 (noiseControlEvent, 0x15), (noiseControlEvent, 0x17),
                 (noiseControlEvent, 0x19), (noiseControlEvent, 0x22):
                return SonyCommands.decodeAmbientSound(payload).map(HeadphonesEvent.ambientSound)
            case (batteryReply, 0x00), (batteryEvent, 0x00):
                return SonyCommands.decodeBattery(payload).map(HeadphonesEvent.battery)
            case (powerParamReply, 0x05), (powerParamEvent, 0x05):
                return SonyCommands.decodeAutomaticPowerOff(payload).map(HeadphonesEvent.automaticPowerOff)
            case (powerParamReply, 0x01), (powerParamEvent, 0x01),
                 (systemParamReply, 0x01), (systemParamEvent, 0x01):
                return SonyCommands.decodePauseWhenTakenOff(payload).map(HeadphonesEvent.pauseWhenTakenOff)
            case (systemParamReply, 0x0c), (systemParamEvent, 0x0c):
                return SonyCommands.decodeSpeakToChatEnabled(payload).map(HeadphonesEvent.speakToChatEnabled)
            case (systemExtParamReply, 0x0c), (systemExtParamEvent, 0x0c):
                return SonyCommands.decodeSpeakToChatConfig(payload).map(HeadphonesEvent.speakToChatConfig)
            case (eqReply, 0x00), (eqReply, 0x02), (eqReply, 0x04),
                 (eqEvent, 0x00), (eqEvent, 0x02), (eqEvent, 0x04):
                return SonyCommands.decodeEqualizer(payload).map(HeadphonesEvent.equalizer)
            case (Self.audioParameterReplyOpcode, 0x09), (Self.audioParameterEventOpcode, 0x09):
                guard let bgm = SonyCommands.decodeBGMMode(payload) else { return nil }
                return .bgmMode(enabled: bgm.enabled, roomSize: bgm.roomSize)
            case (Self.audioParameterReplyOpcode, 0x04), (Self.audioParameterEventOpcode, 0x04):
                return SonyCommands.decodeUpmixCinema(payload).map(HeadphonesEvent.upmixCinema)
            default:
                return nil
            }

        case .secondary:
            guard [Self.peripheralReplyOpcode, Self.peripheralEventOpcode].contains(opcode), payload.count > 1,
                  [0x00, 0x02].contains(payload[1]) else { return nil }
            return SonyCommands.decodeDeviceList(payload).map(HeadphonesEvent.deviceList)

        case .ack:
            return nil
        }
    }
}
