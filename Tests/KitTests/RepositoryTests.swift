import Foundation
import SonyHeadphonesKit

func testNoTestAgentPostsTheProductionNotification() -> Bool {
    let testDirectory = "Tests/KitTests"
    guard let files = try? FileManager.default.contentsOfDirectory(atPath: repositoryRoot.appendingPathComponent(testDirectory).path) else { return false }
    var constructorCount = 0, stateChangedCount = 0
    for file in files.sorted() where file.hasSuffix(".swift") {
        guard let source = repositorySource(testDirectory + "/" + file) else { return false }
        constructorCount += source.components(separatedBy: "XM6ConnectAgentCore" + "(").count - 1
        stateChangedCount += source.components(separatedBy: "state" + "Changed:").count - 1
    }
    return constructorCount > 0 && constructorCount == stateChangedCount
}

func testNoLegacyIdentifierPrefix() -> Bool {
    // Hidden files (Finder's .DS_Store) are not shipping text and are skipped.
    let legacyPrefix = "local" + ".xm6connect"
    let files = ["Sources", "scripts"]
    for directory in files {
        let root = repositoryRoot.appendingPathComponent(directory)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            print("    could not enumerate \(directory)"); return false
        }
        for case let file as URL in enumerator {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) else {
                print("    could not stat \(file.path)"); return false
            }
            if isDirectory.boolValue { continue }
            guard let source = repositorySource(file.path.replacingOccurrences(of: repositoryRoot.path + "/", with: "")) else {
                print("    could not read \(file.path)"); return false
            }
            if source.contains(legacyPrefix) { print("    legacy prefix in \(file.path)"); return false }
        }
    }
    return true
}

private func shippingTextFiles() -> [String] {
    var paths = ["Package.swift"]
    let testDirectory = "Tests/KitTests"
    guard let testFiles = try? FileManager.default.contentsOfDirectory(atPath: repositoryRoot.appendingPathComponent(testDirectory).path) else { return [] }
    paths += testFiles.sorted().filter { $0.hasSuffix(".swift") }.map { testDirectory + "/" + $0 }
    for directory in ["Sources", "scripts"] {
        let root = repositoryRoot.appendingPathComponent(directory)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        for case let file as URL in enumerator {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            paths.append(file.path.replacingOccurrences(of: repositoryRoot.path + "/", with: ""))
        }
    }
    return paths
}

func testShippingTextHasNoDevelopmentHistory() -> Bool {
    let datePattern = "20" + "[0-9]{2}-[0-9]{2}-[0-9]{2}"
    let forbidden = [datePattern, "Mie" + "szko", "/" + "Users/", "Code" + "x", "Cl" + "aude"]
    for path in shippingTextFiles() {
        guard let source = repositorySource(path) else { return false }
        if forbidden.contains(where: { source.range(of: $0, options: .regularExpression) != nil }) {
            print("    development history in \(path)")
            return false
        }
    }
    return true
}

func testBuildScriptSignsAdHocUnlessAsked() -> Bool {
    guard let script = repositorySource("scripts/build_app.sh") else { return false }
    return !script.contains("find" + "-identity")
        && script.contains("CODESIGN_IDENTITY=\"${CODESIGN_IDENTITY:--}\"")
        && script.contains("signing identity: $CODESIGN_IDENTITY")
}

func testBounceACLHasNoAutomaticReopenInSource() -> Bool {
    // This is textual because IOBluetoothDevice cannot be observed without hardware.
    // The hardware check is authoritative; keep the production bounce body free of
    // an independently scheduled reopen as a narrow regression tripwire.
    guard let source = repositorySource("Sources/SonyHeadphonesKit/Bluetooth/RFCOMMConnection.swift"),
          let start = source.range(of: "    public func bounceACL()"),
          let end = source.range(of: "    public func disconnect()", range: start.upperBound..<source.endIndex) else { return false }
    let body = String(source[start.lowerBound..<end.lowerBound])
    return !body.contains("asyncAfter") && !body.contains("openConnection")
}

func testHeadlessRunLoopRequirementIsDocumented() -> Bool {
    guard let source = repositorySource("Sources/XM6ConnectAgent/main.swift") else { return false }
    return source.split(whereSeparator: \.isNewline).last?.trimmingCharacters(in: .whitespaces) == "RunLoop.main.run()"
}

func testChannelDelegateIsClearedInOnePlace() -> Bool {
    guard let source = repositorySource("Sources/SonyHeadphonesKit/Bluetooth/RFCOMMConnection.swift") else { return false }
    return source.components(separatedBy: "setDelegate(nil)").count - 1 == 1
}

func testControllerLogReadsTheDefaultLive() -> Bool {
    guard let source = repositorySource("Sources/SonyHeadphonesKit/HeadphonesController.swift") else {
        print("    L3: HeadphonesController.swift is unreadable"); return false
    }
    guard source.contains("ProtocolLog(enabled:") else { print("    L3: the controller does not build its log with ProtocolLog(enabled:"); return false }
    guard source.contains("\"protocolLoggingEnabled\"") else { print("    L3: the controller does not name the protocolLoggingEnabled default"); return false }
    guard !source.contains("protocolLog.isEnabled =") else { print("    L3: the controller still assigns protocolLog.isEnabled once"); return false }
    return true
}

func testSegmentedPickersHideTheirRedundantLabel() -> Bool {
    // A LINT, and labelled as one: a segmented picker claims the full width, leaving its
    // label about one character, which SwiftUI then wraps to one letter per line down the
    // card edge. No behavioural test can see it, because the defect is in layout, not
    // logic. Both cards already carry a header naming them.
    guard let source = repositorySource("Sources/XM6ConnectApp/PopoverView.swift") else { return false }
    let pickers = source.components(separatedBy: "pickerStyle(.segmented)").dropFirst()
    return pickers.count >= 2 && pickers.allSatisfy { $0.contains(".labelsHidden()") }
}

func testConnectionFailureIsDeliveredSynchronously() -> Bool {
    // The controller tags each event with the attempt it belongs to when onEvent runs, so a
    // failure must reach it without a main-queue hop that a newer attempt could start in.
    guard let source = repositorySource("Sources/SonyHeadphonesKit/Bluetooth/RFCOMMConnection.swift"),
          let start = source.range(of: "private func emitFailure("),
          let end = source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex) else {
        print("    emitFailure not found"); return false
    }
    let body = source[start.upperBound..<end.lowerBound]
    guard body.contains("onEvent?(.failed(message))"), !body.contains("post(") else {
        print("    emitFailure does not deliver .failed synchronously"); return false
    }
    return true
}

func testWidgetSourcesDoNotReferencePrewarm() -> Bool {
    let widgetDirectory = repositoryRoot.appendingPathComponent("Sources/XM6ConnectWidget")
    guard let files = try? FileManager.default.contentsOfDirectory(
        at: widgetDirectory,
        includingPropertiesForKeys: nil
    ) else { return false }
    return files.filter { $0.pathExtension == "swift" }.allSatisfy {
        guard let source = try? String(contentsOf: $0, encoding: .utf8) else { return false }
        return !source.contains(".prewarm")
    }
}

func testWidgetReloadsHaveOneCaller() -> Bool {
    let appDirectory = repositoryRoot.appendingPathComponent("Sources/XM6ConnectApp")
    guard let files = try? FileManager.default.contentsOfDirectory(at: appDirectory, includingPropertiesForKeys: nil) else { return false }
    var sources: [String] = []
    for file in files where file.pathExtension == "swift" {
        guard let source = repositorySource("Sources/XM6ConnectApp/\(file.lastPathComponent)") else { return false }
        sources.append(source)
    }
    func count(_ needle: String) -> Int { sources.reduce(0) { $0 + $1.components(separatedBy: needle).count - 1 } }
    // One widget reload, and no Control Center reload: there is no control to reload.
    let timelines = count("reloadTimelines(ofKind:"), controls = count("reloadControls(ofKind:")
    guard timelines == 1, controls == 0 else { print("    reloadTimelines: \(timelines), reloadControls: \(controls)"); return false }
    return true
}

// An App Intent only runs once its metadata has been generated, and the tool that
// generates it ships with Xcode, not with the Command Line Tools this project builds
// with. A `ControlWidget` can only act through an intent, so its button is inert: the
// system looks the intent up, finds nothing, and the tap does nothing at all. The widget
// drives its own buttons with `Link` instead, which needs no metadata.
func testWidgetDeclaresNoAppIntentOrControl() -> Bool {
    let widgetDirectory = repositoryRoot.appendingPathComponent("Sources/XM6ConnectWidget")
    guard let files = try? FileManager.default.contentsOfDirectory(at: widgetDirectory, includingPropertiesForKeys: nil) else { return false }
    for file in files {
        guard let data = try? Data(contentsOf: file) else { continue }
        let source = String(decoding: data, as: UTF8.self)
        for marker in [": AppIntent", ": ControlWidget", "ControlWidgetButton", "OpenURLIntent"] where source.contains(marker) {
            print("    \(file.lastPathComponent) declares \(marker), which cannot work without Xcode-generated metadata")
            return false
        }
    }
    return true
}

func testBuildScriptWritesNoBundledLaunchAgent() -> Bool {
    guard let script = repositorySource("scripts/build_app.sh") else { return false }
    return !script.contains("Contents/Library/LaunchAgents")
}

func testSocketPathHasOneSpelling() -> Bool {
    let files = ["Sources/XM6ConnectAgent/main.swift", "Sources/XM6ConnectCtl/main.swift", "Sources/XM6ConnectApp/PopoverModel.swift"]
    var problems: [String] = []
    for file in files {
        guard let source = repositorySource(file) else {
            problems.append("\(file): unreadable"); continue
        }
        if !source.contains("agentSocketPath(") { problems.append("\(file): no agentSocketPath(") }
        if source.contains("\"agent.sock\"") { problems.append("\(file): literal \"agent.sock\"") }
        if source.contains("XM6Connect/agent.sock") { problems.append("\(file): literal XM6Connect/agent.sock") }
    }
    if !problems.isEmpty { print("    socket path spelling: " + problems.joined(separator: "; ")) }
    return problems.isEmpty
}

func testWidgetStateEntitlementsMatchSharedPath() -> Bool {
    func plist(at relativePath: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: repositoryRoot.appendingPathComponent(relativePath)) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }
    guard let widget = plist(at: "Sources/XM6ConnectWidget/entitlements.plist"),
          let host = plist(at: "Sources/XM6ConnectApp/entitlements.plist") else { return false }
    return widget["com.apple.security.app-sandbox"] as? Bool == true
        && widget["com.apple.security.temporary-exception.files.home-relative-path.read-only"] as? [String]
            == ["/" + XM6ConnectPaths.agentSupportDirectoryRelativePath + "/"]
        && widget["com.apple.security.application-groups"] == nil
        && host["com.apple.security.application-groups"] == nil
}
