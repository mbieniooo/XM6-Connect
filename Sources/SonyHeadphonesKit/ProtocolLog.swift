import Foundation

/// Appends a hex dump of every frame sent/received to
/// `~/Library/Application Support/XM6Connect/protocol.log`, so protocol issues on
/// real hardware (features not yet verified on XM6) can
/// be diagnosed from a session transcript instead of guesswork.
///
/// The switch is the `protocolLoggingEnabled` user default, read through the `enabled`
/// closure on every write, so turning it off stops the log at once without a restart.
/// The file is private to the user (mode 0600): it holds every frame, including the
/// headset's Bluetooth address and name.
public final class ProtocolLog {
    /// When false (the default), nothing is written -- zero disk I/O in steady state.
    public var isEnabled: Bool { enabled() }

    private let enabled: () -> Bool
    private let url: URL?
    private let formatter: DateFormatter
    /// Set once this instance has made an existing log file private, so the mode is
    /// checked on the first append only, not on every line.
    private var permissionsChecked = false

    private static let maximumBytes = 2_000_000

    public init(baseURL: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first, enabled: @escaping () -> Bool = { false }) {
        self.enabled = enabled
        formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"

        if let dir = baseURL?.appendingPathComponent("XM6Connect", isDirectory: true) {
            url = dir.appendingPathComponent("protocol.log")
        } else {
            url = nil
        }
    }

    public var logURLForTesting: URL? { url }

    public func startSession(deviceName: String?) {
        guard isEnabled else { return }
        appendLine("=== session \(Date()) device=\(deviceName ?? "?") ===\n")
    }

    public func log(_ direction: String, _ bytes: [UInt8], note: String = "") {
        guard isEnabled else { return }
        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        appendLine("\(formatter.string(from: Date())) \(direction) \(hex)\(note.isEmpty ? "" : "  // \(note)")\n")
    }

    private func appendLine(_ line: String) {
        guard let url, let data = line.data(using: .utf8) else { return }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Rotate only when the log gets big; never truncate on reconnect, otherwise
        // an auto-reconnect wipes the evidence the log exists to preserve. The check runs
        // on every append so a log switched on in the middle of a long session stays bounded.
        if let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int,
           size > Self.maximumBytes {
            try? fileManager.removeItem(at: url)
        }
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
            permissionsChecked = true
            return
        }
        if !permissionsChecked {
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            permissionsChecked = true
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}
