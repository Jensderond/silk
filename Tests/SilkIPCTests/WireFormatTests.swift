import Foundation
import Testing
@testable import SilkIPC

/// Byte-level fixtures as produced by AeroSpace 0.21.3 (`JSONEncoder()` for requests/answers,
/// `[.withoutEscapingSlashes, .sortedKeys]` for events).
@Suite struct WireFormatTests {
    private func json(_ value: some Encodable, encoder: JSONEncoder = WireProtocol.makeMessageEncoder()) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// AeroSpace's message encoder doesn't sort keys, so key order is unspecified; compare with sorted keys
    /// (which leaves every other formatting choice, e.g. `\/` escaping, untouched).
    private func sortedJSON(_ value: some Encodable) throws -> String {
        let encoder = WireProtocol.makeMessageEncoder()
        encoder.outputFormatting.insert(.sortedKeys)
        return try json(value, encoder: encoder)
    }

    @Test func integersAreFourLittleEndianBytes() {
        #expect(WireProtocol.encodeUInt32(1) == Data([1, 0, 0, 0]))
        #expect(WireProtocol.encodeUInt32(0x0102_0304) == Data([4, 3, 2, 1]))
        #expect(WireProtocol.decodeUInt32(Data([4, 3, 2, 1])) == 0x0102_0304)
        #expect(WireProtocol.decodeUInt32(Data([1, 0, 0])) == nil)
    }

    @Test func frameIsLengthPrefixedPayload() {
        #expect(WireProtocol.frame(Data("{}".utf8)) == Data([2, 0, 0, 0, 0x7B, 0x7D]))
        #expect(WireProtocol.frame(Data()) == Data([0, 0, 0, 0]))
    }

    @Test func requestEncodesLikeTheAeroSpaceCLI() throws {
        let plain = try sortedJSON(ClientRequest(args: ["workspace", "1"]))
        #expect(plain == #"{"args":["workspace","1"],"stdin":"","windowId":null,"workspace":null}"#)
        let full = try sortedJSON(ClientRequest(args: ["exec-and-forget", "open /Applications"], stdin: "a\n", windowId: 42, workspace: "M"))
        #expect(full == #"{"args":["exec-and-forget","open \/Applications"],"stdin":"a\n","windowId":42,"workspace":"M"}"#)
    }

    @Test func requestDecodesAeroSpaceFixtures() throws {
        let decode = { (json: String) in try JSONDecoder().decode(ClientRequest.self, from: Data(json.utf8)) }

        let cli = try decode(#"{"args":["list-monitors","--count"],"stdin":"","windowId":null,"workspace":null}"#)
        #expect(cli == ClientRequest(args: ["list-monitors", "--count"]))
        #expect(cli.hasContextFields)

        let callback = try decode(#"{"args":["move-node-to-workspace","--window-id","7","X"],"stdin":"","windowId":7,"workspace":"X"}"#)
        #expect(callback.windowId == 7)
        #expect(callback.workspace == "X")

        let legacy = try decode(#"{"command":"","args":["focus","left"],"stdin":""}"#)
        #expect(legacy.args == ["focus", "left"])
        #expect(!legacy.hasContextFields)

        let halfLegacy = try decode(#"{"args":[],"stdin":"","windowId":null}"#)
        #expect(!halfLegacy.hasContextFields)

        #expect(throws: DecodingError.self) { try decode(#"{"args":[],"stdin":"","windowId":-1,"workspace":null}"#) }
        #expect(throws: DecodingError.self) { try decode(#"{"stdin":""}"#) }
    }

    @Test func requestRoundTrips() throws {
        let request = ClientRequest(args: ["eval", "--stdin"], stdin: "workspace 1\nfocus left\n", windowId: 1234, workspace: "Ω")
        #expect(try JSONDecoder().decode(ClientRequest.self, from: WireProtocol.makeMessageEncoder().encode(request)) == request)
    }

    @Test func answerMatchesAeroSpaceFixture() throws {
        let fixture = #"{"exitCode":0,"serverVersionAndHash":"0.20.0-Beta 33fa0643","stderr":"","stdout":"1\n2\n3"}"#
        let answer = try JSONDecoder().decode(ServerAnswer.self, from: Data(fixture.utf8))
        #expect(answer == ServerAnswer(exitCode: 0, stdout: "1\n2\n3", serverVersionAndHash: "0.20.0-Beta 33fa0643"))
        let encoded = try sortedJSON(answer)
        #expect(encoded == fixture)
    }

    @Test func eventsEncodeLikeAeroSpaceDocs() throws {
        let encoder = WireProtocol.makeEventEncoder()
        #expect(try json(ServerEvent.focusedMonitorChanged(workspace: "M", monitorId: 1), encoder: encoder)
            == #"{"_event":"focused-monitor-changed","monitorId":1,"workspace":"M"}"#)
        #expect(try json(ServerEvent.workspaceChanged(workspace: "M", prevWorkspace: "M"), encoder: encoder)
            == #"{"_event":"focused-workspace-changed","prevWorkspace":"M","workspace":"M"}"#)
        #expect(try json(ServerEvent.modeChanged(mode: "main"), encoder: encoder) == #"{"_event":"mode-changed","mode":"main"}"#)
        #expect(try json(ServerEvent.modeChanged(mode: nil), encoder: encoder) == #"{"_event":"mode-changed"}"#)
        #expect(try json(ServerEvent.focusChanged(windowId: 28218, workspace: "M"), encoder: encoder)
            == #"{"_event":"focus-changed","windowId":28218,"workspace":"M"}"#)
        #expect(try json(ServerEvent.focusChanged(windowId: nil, workspace: "1"), encoder: encoder)
            == #"{"_event":"focus-changed","workspace":"1"}"#)
        #expect(try json(ServerEvent.windowDetected(windowId: 5, workspace: "W", appBundleId: "com.tinyspeck.slackmacgap", appName: "Slack"), encoder: encoder)
            == #"{"_event":"window-detected","appBundleId":"com.tinyspeck.slackmacgap","appName":"Slack","windowId":5,"workspace":"W"}"#)
        #expect(try json(ServerEvent.bindingTriggered(mode: "main", binding: "alt-h/j"), encoder: encoder)
            == #"{"_event":"binding-triggered","binding":"alt-h/j","mode":"main"}"#)
    }

    @Test func eventsRoundTrip() throws {
        let event = ServerEvent.windowDetected(windowId: 5, workspace: nil, appBundleId: nil, appName: "Finder")
        let decoded = try JSONDecoder().decode(ServerEvent.self, from: WireProtocol.makeEventEncoder().encode(event))
        #expect(decoded == event)
        #expect(decoded.eventType == .windowDetected)
    }
}

@Suite struct SubscribeArgumentsTests {
    private let possibleValues = "(focus-changed|focused-monitor-changed|focused-workspace-changed|mode-changed|window-detected|binding-triggered)"

    @Test func validForms() {
        #expect(SubscribeArguments.parse(["--all"]) == .subscribe(SubscribeArguments(events: Set(ServerEventType.allCases), sendInitial: true)))
        #expect(SubscribeArguments.parse(["focus-changed", "mode-changed", "--no-send-initial"])
            == .subscribe(SubscribeArguments(events: [.focusChanged, .modeChanged], sendInitial: false)))
        #expect(SubscribeArguments.parse(["--no-send-initial", "--all"])
            == .subscribe(SubscribeArguments(events: Set(ServerEventType.allCases), sendInitial: false)))
    }

    @Test func help() {
        #expect(SubscribeArguments.parse(["--help"]) == .help("USAGE: subscribe [-h|--help] [--all] [--no-send-initial] [<event>...]"))
        #expect(SubscribeArguments.parse(["focus-changed", "-h"]) == .help(SubscribeArguments.help))
    }

    @Test func errorsMatchAeroSpace() {
        #expect(SubscribeArguments.parse([]) == .failure("Either --all or at least one <event> must be specified"))
        #expect(SubscribeArguments.parse(["--all", "focus-changed"]) == .failure("--all conflicts with specifying individual events"))
        #expect(SubscribeArguments.parse(["--bogus"]) == .failure("ERROR: Unknown flag '--bogus'"))
        #expect(SubscribeArguments.parse(["--all", "--all"]) == .failure("ERROR: Duplicated option '--all'"))
        #expect(SubscribeArguments.parse(["focus"]) == .failure("ERROR: Can't parse 'focus'.\n       Possible values: \(possibleValues)"))
        #expect(SubscribeArguments.parse(["mode-changed", "mode-changed"]) == .failure("ERROR: Duplicate event 'mode-changed'"))
        #expect(SubscribeArguments.parse(["mode-changed", "--all", "focus-changed"]) == .failure("ERROR: Unknown argument 'focus-changed'"))
        #expect(SubscribeArguments.parse(["--", "focus-changed"])
            == .failure("ERROR: Can't parse '--'.\n       Possible values: \(possibleValues)\nERROR: Unknown argument 'focus-changed'"))
    }
}

@Suite struct AeroSpaceClientVersionProbeTests {
    /// Lays constants out the way the Swift compiler does: the hash as a C string, the version as an
    /// aligned 16-byte small-string record.
    private func syntheticBinary(version: String, hash: String, extraVersions: [String] = []) -> Data {
        var data = Data(repeating: 0xAA, count: 64)
        data.append(0)
        data.append(contentsOf: Array(hash.utf8))
        data.append(0)
        data.append(Data("unrelated\0deadbeef\0".utf8))
        for version in [version] + extraVersions {
            while data.count % 8 != 0 { data.append(0xCC) }
            var record = Array(version.utf8) + Array(repeating: 0, count: 15 - version.utf8.count)
            record.append(0xE0 | UInt8(version.utf8.count))
            data.append(contentsOf: record)
        }
        data.append(Data(repeating: 0xBB, count: 32))
        return data
    }

    @Test func findsVersionAndHash() {
        let data = syntheticBinary(version: "0.21.3-Beta", hash: "d56e1637c3a1ed660d0cadd7534e94fb3218d1c3")
        #expect(AeroSpaceClientVersionProbe.scan(data) == "0.21.3-Beta d56e1637c3a1ed660d0cadd7534e94fb3218d1c3")
        #expect(AeroSpaceClientVersionProbe.scan(syntheticBinary(version: "1.0.0", hash: String(repeating: "a", count: 40))) == "1.0.0 \(String(repeating: "a", count: 40))")
    }

    @Test func refusesAmbiguousOrMissingData() {
        let hash = "d56e1637c3a1ed660d0cadd7534e94fb3218d1c3"
        #expect(AeroSpaceClientVersionProbe.scan(syntheticBinary(version: "0.21.3-Beta", hash: hash, extraVersions: ["0.20.0"])) == nil)
        #expect(AeroSpaceClientVersionProbe.scan(syntheticBinary(version: "not-a-version", hash: hash)) == nil)
        #expect(AeroSpaceClientVersionProbe.scan(syntheticBinary(version: "0.21.3", hash: "D56E1637C3A1ED660D0CADD7534E94FB3218D1C3")) == nil)
        #expect(AeroSpaceClientVersionProbe.scan(Data(count: 4096)) == nil)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/opt/homebrew/bin/aerospace")))
    func readsInstalledAeroSpaceCLI() throws {
        let path = URL(fileURLWithPath: "/opt/homebrew/bin/aerospace").resolvingSymlinksInPath().path
        let detected = try #require(AeroSpaceClientVersionProbe().versionAndHash(ofExecutableAt: path))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(output.hasPrefix("aerospace CLI client version: \(detected)\n"))
    }

    @Test func nonAeroSpaceExecutableHasNoVersion() {
        #expect(AeroSpaceClientVersionProbe().versionAndHash(ofExecutableAt: "/bin/ls") == nil)
        #expect(AeroSpaceClientVersionProbe().versionAndHash(ofProcess: getpid()) == nil)
    }
}
