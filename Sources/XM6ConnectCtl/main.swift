import Darwin
import Foundation
import SonyHeadphonesKit
import XM6ConnectAgentCore

private let socketPath = XM6ConnectPaths.agentSocketPath()

private func usage() -> Never {
    fputs("usage: xm6ctl status [--json] | refresh | yield [seconds] | hold on|off | mode nc|ambient|off | cycle | ambient 1-20 | focus on|off | listening standard|bgm|cinema | bgm-room small|middle|large | eq preset <name|code> | eq bands <10 ints> | stc on|off | playback <name|mac> | reconnect\n", stderr)
    exit(64)
}

private func request(_ object: [String: Any]) -> [String: Any]? {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { _ = close(fd) }
    var noSIGPIPE: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    guard let connected = withUnixSocketAddress(socketPath, { Darwin.connect(fd, $0, $1) }) else { return nil }
    guard connected == 0 else { return nil }
    var line = data; line.append(0x0a)
    guard line.withUnsafeBytes({ Darwin.send(fd, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }) == line.count else { return nil }
    var reply = Data(), chunk = [UInt8](repeating: 0, count: 4096)
    while reply.count <= 64 * 1024 {
        let count = Darwin.read(fd, &chunk, chunk.count)
        guard count > 0 else { break }
        reply.append(chunk, count: count)
        if reply.contains(0x0a) { break }
    }
    return (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
}

private func printReply(_ reply: [String: Any], json: Bool) {
    if let error = reply["error"] as? String { fputs("xm6ctl: \(error)\n", stderr) }
    guard let data = try? JSONSerialization.data(withJSONObject: reply, options: [.prettyPrinted, .sortedKeys]) else { return }
    if json { print(String(decoding: data, as: UTF8.self)); return }
    if let ownership = reply["ownership"] as? String { print("ownership: \(ownership)") }
    if let asOf = reply["stateAsOf"] as? String, let date = ISO8601DateFormatter().date(from: asOf) {
        print("state age: \(max(0, Int(Date().timeIntervalSince(date))))s")
    }
    if let state = reply["state"] as? [String: Any], let mode = state["listeningMode"] as? String {
        print("listening mode: \(mode)")
    }
    if let devices = multipointDevices(in: reply), !devices.isEmpty {
        print("multipoint:")
        for device in devices {
            let source = device.playback ? "▶ playing" : (device.connected ? "connected" : "not connected")
            print("  \(source): \(device.name) (\(device.macAddress))")
        }
    }
    print(String(decoding: data, as: UTF8.self))
}

private func status() -> [String: Any] {
    guard let answer = request(["cmd": "status"]) else { fputs("xm6ctl: XM6ConnectAgent is not running or did not reply within 5 seconds\n", stderr); exit(1) }
    return answer
}
private func bool(_ value: String) -> Bool? { value == "on" ? true : (value == "off" ? false : nil) }
private func multipointDevices(in reply: [String: Any]) -> [AgentMultipointDevice]? {
    guard let state = reply["state"] as? [String: Any], let raw = state["multipoint"] as? [[String: Any]],
          let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
    return try? JSONDecoder().decode([AgentMultipointDevice].self, from: data)
}

let args = Array(CommandLine.arguments.dropFirst())
_ = signal(SIGPIPE, SIG_IGN)
guard let command = args.first else { usage() }
let answer: [String: Any]?
switch command {
case "status": let result = status(); printReply(result, json: args.dropFirst().contains("--json")); exit((result["error"] as? String) == nil ? 0 : 1)
case "cycle": answer = request(["cmd": "cycle"])
case "reconnect": answer = request(["cmd": "reconnect"])
case "refresh": answer = request(["cmd": "refresh"])
case "yield":
    guard args.count <= 2 else { usage() }
    if args.count == 1 { answer = request(["cmd": "yield"]) }
    else { guard let seconds = Int(args[1]), seconds > 0 else { usage() }; answer = request(["cmd": "yield", "seconds": seconds]) }
case "hold":
    guard args.count == 2, let enabled = bool(args[1]) else { usage() }
    answer = request(["cmd": "hold", "enabled": enabled])
case "mode":
    guard args.count == 2, ["nc", "ambient", "off"].contains(args[1]) else { usage() }
    // Only the mode: the agent takes level and focus from the headset's current report.
    answer = request(["cmd": "set_mode", "mode": args[1]])
case "ambient":
    guard args.count == 2, let level = Int(args[1]), (1...20).contains(level) else { usage() }
    // Only the level: the agent switches to Ambient and keeps the focus the headset reports.
    answer = request(["cmd": "set_ambient_level", "level": level])
case "focus":
    guard args.count == 2, let enabled = bool(args[1]) else { usage() }
    // Only focus: the agent keeps the mode and level the headset reports.
    answer = request(["cmd": "set_focus", "enabled": enabled])
case "stc":
    guard args.count == 2, let enabled = bool(args[1]) else { usage() }
    answer = request(["cmd": "set_stc", "enabled": enabled])
case "playback":
    guard args.count == 2 else { usage() }
    let response = status()
    guard let devices = multipointDevices(in: response) else {
        fputs("xm6ctl: multipoint device list is unavailable; run xm6ctl refresh and try again\n", stderr); exit(1)
    }
    var playbackReply: [String: Any]?
    switch PlaybackTargetResolver.dispatch(args[1], in: devices, send: { macAddress in
        playbackReply = request(["cmd": "switch_playback", "mac": macAddress])
    }) {
    case .success: answer = playbackReply
    case .failure(let error): fputs("xm6ctl: \(error.description)\n", stderr); exit(1)
    }
case "listening":
    guard args.count == 2 else { usage() }
    let aliases = ["standard": "standard", "bgm": "backgroundMusic", "backgroundmusic": "backgroundMusic", "cinema": "cinema"]
    guard let mode = aliases[args[1].lowercased()] else { usage() }
    answer = request(["cmd": "set_listening_mode", "mode": mode])
case "bgm-room":
    guard args.count == 2 else { usage() }
    let rooms = ["small": 0x00, "middle": 0x01, "large": 0x02]
    guard let roomSize = rooms[args[1].lowercased()] else { usage() }
    answer = request(["cmd": "set_bgm_room_size", "roomSize": roomSize])
case "eq":
    guard args.count >= 3 else { usage() }
    if args[1] == "preset", args.count == 3 {
        // Preset names are the kit's `EqualizerPreset` labels, matched case-insensitively.
        guard let code = EqualizerPresetResolver.code(for: args[2]) else { usage() }
        answer = request(["cmd": "set_eq_preset", "code": code])
    } else if args[1] == "bands", args.count == 12 {
        let bands = args.dropFirst(2).compactMap(Int.init)
        guard bands.count == 10 else { usage() }
        answer = request(["cmd": "set_eq_bands", "bands": bands])
    } else { usage() }
default: usage()
}
guard let response = answer else { fputs("xm6ctl: XM6ConnectAgent is not running or did not reply within 5 seconds\n", stderr); exit(1) }
printReply(response, json: true)
exit((response["error"] as? String) == nil ? 0 : 1)
