import Foundation

public enum SonyMessageType: UInt8, Equatable, Sendable {
    case ack = 0x01
    case primary = 0x0c
    case secondary = 0x0e
}

public struct SonyMessage: Equatable, Sendable {
    public static let frameStart: UInt8 = 0x3e
    public static let frameEnd: UInt8 = 0x3c
    public static let escapeMarker: UInt8 = 0x3d
    public static let escapeOffset: UInt8 = 0x10

    public let type: SonyMessageType
    public let sequenceNumber: UInt8
    public let payload: [UInt8]

    public init(type: SonyMessageType, sequenceNumber: UInt8, payload: [UInt8]) {
        self.type = type
        self.sequenceNumber = sequenceNumber
        self.payload = payload
    }

    public func encode() -> [UInt8] {
        precondition(payload.count <= Int(UInt32.max))
        let length = UInt32(payload.count)
        var body: [UInt8] = [type.rawValue, sequenceNumber]
        body += [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: length >> $0) }
        body += payload
        body.append(Self.checksum(body))

        var frame = [Self.frameStart]
        for byte in body {
            switch byte {
            case Self.frameStart, Self.frameEnd, Self.escapeMarker:
                frame += [Self.escapeMarker, byte &- Self.escapeOffset]
            default:
                frame.append(byte)
            }
        }
        frame.append(Self.frameEnd)
        return frame
    }

    public static func decode(rawFrame: [UInt8]) -> SonyMessage? {
        guard rawFrame.count >= 9,
              rawFrame.first == frameStart,
              rawFrame.last == frameEnd else { return nil }

        guard let body = unescape(Array(rawFrame.dropFirst().dropLast())), body.count >= 7,
              let type = SonyMessageType(rawValue: body[0]) else { return nil }

        let declaredLength = body[2...5].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let payloadLength = body.count - 7
        guard declaredLength == UInt64(payloadLength),
              checksum(Array(body.dropLast())) == body.last else { return nil }

        return SonyMessage(type: type, sequenceNumber: body[1], payload: Array(body[6..<(6 + payloadLength)]))
    }

    public static func checksum(_ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(0) { $0 &+ $1 }
    }

    private static func unescape(_ bytes: [UInt8]) -> [UInt8]? {
        var result: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            guard byte != escapeMarker else {
                guard index + 1 < bytes.count else { return nil }
                let escaped = bytes[index + 1]
                guard (0x2c...0x2e).contains(escaped) else { return nil }
                result.append(escaped &+ escapeOffset)
                index += 2
                continue
            }
            result.append(byte)
            index += 1
        }
        return result
    }
}

public final class FrameParser {
    private static let maximumBufferedBytes = 8192
    private var buffer: [UInt8] = []

    public init() {}

    public var bufferedByteCount: Int { buffer.count }

    public func reset() {
        buffer.removeAll()
    }

    public func feed(_ data: [UInt8]) -> [SonyMessage] {
        buffer += data
        var messages: [SonyMessage] = []

        while true {
            guard let start = buffer.firstIndex(of: SonyMessage.frameStart) else {
                buffer.removeAll()
                break
            }
            if start > 0 {
                buffer.removeFirst(start)
            }
            guard let end = buffer.dropFirst().firstIndex(of: SonyMessage.frameEnd) else {
                if buffer.count > Self.maximumBufferedBytes { buffer.removeAll() }
                break
            }

            let frame = Array(buffer[...end])
            if let message = SonyMessage.decode(rawFrame: frame) {
                messages.append(message)
                buffer.removeFirst(end + 1)
            } else if let innerStart = buffer[1...end].firstIndex(of: SonyMessage.frameStart) {
                buffer.removeFirst(innerStart)
            } else {
                buffer.removeFirst(end + 1)
            }
        }
        return messages
    }
}
