import Foundation
import Testing
@testable import EnsembleCore

struct SafetyRecordFileTests {
    private let fm = FileManager.default

    private func folder() -> URL {
        fm.temporaryDirectory.appendingPathComponent("ensemble-record-\(UUID().uuidString)", isDirectory: true)
    }

    private func isLink(_ url: URL) -> Bool {
        (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    @Test func aLinkPlantedAtTheTempNameIsNotFollowed() throws {
        let dir = folder()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let victim = dir.appendingPathComponent("victim")
        try Data("keep".utf8).write(to: victim)
        try fm.createSymbolicLink(at: dir.appendingPathComponent("episode.json.tmp"), withDestinationURL: victim)

        try SafetyRecordFile.write(Data("record".utf8), to: dir.appendingPathComponent("episode.json"))

        #expect(try Data(contentsOf: victim) == Data("keep".utf8))
        #expect(try Data(contentsOf: dir.appendingPathComponent("episode.json")) == Data("record".utf8))
        #expect(!isLink(dir.appendingPathComponent("episode.json")))
        #expect(!isLink(dir.appendingPathComponent("episode.json.tmp")))
    }

    @Test func theTempFileIsNeverOpenedThroughALink() throws {
        let dir = folder()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let victim = dir.appendingPathComponent("victim")
        try Data("keep".utf8).write(to: victim)
        let link = dir.appendingPathComponent("mute.json.1.tmp")
        try fm.createSymbolicLink(at: link, withDestinationURL: victim)

        #expect(throws: POSIXError.self) { try SafetyRecordFile.createExclusive(link) }
        #expect(try Data(contentsOf: victim) == Data("keep".utf8))
    }

    @Test func aLooserFolderIsMadePrivateOnTheNextWrite() throws {
        let dir = folder()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])

        try SafetyRecordFile.write(Data("record".utf8), to: dir.appendingPathComponent("mute.json"))

        #expect(try fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int == 0o700)
        #expect(try fm.attributesOfItem(atPath: dir.appendingPathComponent("mute.json").path)[.posixPermissions] as? Int == 0o600)
    }

    @Test func tempFilesLeftByACrashAreRemovedOnTheNextWrite() throws {
        let dir = folder()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["mute.json.tmp", "mute.json.0A1B.tmp", "episode.json.0A1B.tmp"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }

        try SafetyRecordFile.write(Data("record".utf8), to: dir.appendingPathComponent("mute.json"))

        #expect(Set(try fm.contentsOfDirectory(atPath: dir.path)) == ["mute.json", "episode.json.0A1B.tmp"])
    }

    @Test func aWriteThatCannotLandThrowsAndLeavesNoTempFile() throws {
        let dir = folder()
        let record = dir.appendingPathComponent("episode.json")
        try fm.createDirectory(at: record.appendingPathComponent("blocker"), withIntermediateDirectories: true)

        #expect(throws: POSIXError.self) { try SafetyRecordFile.write(Data("record".utf8), to: record) }
        #expect(try fm.contentsOfDirectory(atPath: dir.path) == ["episode.json"])
    }

    @Test func removingARecordLeavesNoFile() throws {
        let dir = folder()
        let record = dir.appendingPathComponent("episode.json")
        try SafetyRecordFile.write(Data("record".utf8), to: record)

        SafetyRecordFile.remove(record)
        SafetyRecordFile.remove(record)

        #expect(try fm.contentsOfDirectory(atPath: dir.path).isEmpty)
    }
}
