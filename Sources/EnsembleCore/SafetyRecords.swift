import Foundation

/// A dictation press that has been started and not yet proven finished. Written (and fsynced) before the
/// press so that a crash mid-recording is discoverable on the next launch.
public struct EpisodeRecord: Codable, Equatable {
    public var id: String
    public var startedAt: Date
    public var pid: Int32
    public var bootSessionUUID: String
    public var sessionID: String
    public var claudeVersion: String?

    public init(id: String, startedAt: Date, pid: Int32, bootSessionUUID: String, sessionID: String, claudeVersion: String?) {
        self.id = id
        self.startedAt = startedAt
        self.pid = pid
        self.bootSessionUUID = bootSessionUUID
        self.sessionID = sessionID
        self.claudeVersion = claudeVersion
    }
}

/// An input-device mute (or volume-to-zero) that this app applied as a last-resort safeguard.
public struct MuteRecord: Codable, Equatable {
    public enum Method: String, Codable { case mute, volume }
    public var deviceUID: String
    public var method: Method
    public var priorMuted: Bool?
    public var priorVolume: Float?
    public var appliedAt: Date

    public init(deviceUID: String, method: Method, priorMuted: Bool?, priorVolume: Float?, appliedAt: Date) {
        self.deviceUID = deviceUID
        self.method = method
        self.priorMuted = priorMuted
        self.priorVolume = priorVolume
        self.appliedAt = appliedAt
    }
}

public enum SafetyRecordCoding {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// Writes and deletes the safety records. A record exists to stop Claude's dictation after a crash, so neither a link
/// planted in the folder nor a crash right after a write or delete may leave a different record than the app last chose.
public enum SafetyRecordFile {
    /// Write to a fresh temp file nobody could have planted, force it to disk, rename it over `url`, then force the
    /// folder entry. Throws when the record is not on disk, so the caller does not press Claude's dictation without one.
    public static func write(_ data: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try ensureFolder(folder)
        // Temp files a crash left behind would otherwise pile up, one unique name per write.
        let prefix = url.lastPathComponent + "."
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path)
        where name.hasPrefix(prefix) && name.hasSuffix(".tmp") {
            remove(folder.appendingPathComponent(name))
        }
        let tmp = folder.appendingPathComponent("\(prefix)\(UUID().uuidString).tmp")
        let handle = try createExclusive(tmp)
        do {
            try handle.write(contentsOf: data)
#if canImport(Darwin)
            if fcntl(handle.fileDescriptor, F_FULLFSYNC) != 0 { try handle.synchronize() }
#else
            // F_FULLFSYNC is Apple's; elsewhere synchronize() is the flush the system offers.
            try handle.synchronize()
#endif
            try handle.close()
            guard rename(tmp.path, url.path) == 0 else { throw posixError() }
        } catch {
            remove(tmp)
            throw error
        }
        syncFolder(folder)
    }

    /// Delete, then force the folder entry so a crash cannot bring the old record back. A failed delete is not an
    /// error: the record stays, and the recovery acts on it again.
    public static func remove(_ url: URL) {
        guard unlink(url.path) == 0 else { return }
        syncFolder(url.deletingLastPathComponent())
    }

    static func syncFolder(_ folder: URL) {
#if os(Windows)
        // A folder cannot be opened and flushed like a file there.
        _ = folder
#else
        let fd = open(folder.path, O_RDONLY)
        if fd >= 0 { _ = fsync(fd); close(fd) }
#endif
    }

    /// Creating a folder applies its mode only when it is new, so an existing one is tightened every time.
    static func ensureFolder(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }

    /// Refuses any file or link already at `url`, so the write cannot be redirected.
    static func createExclusive(_ url: URL) throws -> FileHandle {
#if os(Windows)
        // No O_NOFOLLOW there; O_EXCL alone still refuses an existing file or link.
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
#else
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
#endif
        guard fd >= 0 else { throw posixError() }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

/// The safety records an older build left in its own application-support folder are the only trace of a dictation
/// that build left recording, or of an input device it muted. On launch they are moved into the current folder, where
/// the normal recovery code finds them, acts on them and deletes them. Nothing is dropped: when both folders hold a
/// file of the same name the two are merged, and a file that cannot be moved stays where it is for the next launch.
public enum SafetyFolderMigration {
    public static let episodeName = "episode.json"
    public static let muteName = "mute.json"

    /// Returns the names of the files that were moved or merged into `current`. Removes `legacy` when it ends up empty.
    @discardableResult
    public static func adopt(from legacy: URL, into current: URL) -> [String] {
        let fm = FileManager.default
        var adopted: [String] = []
        for name in [episodeName, muteName] {
            let from = legacy.appendingPathComponent(name)
            guard fm.fileExists(atPath: from.path) else { continue }
            let to = current.appendingPathComponent(name)
            do {
                try SafetyRecordFile.ensureFolder(current)
                if fm.fileExists(atPath: to.path) {
                    let merged = merge(name: name, legacy: try Data(contentsOf: from), current: try Data(contentsOf: to))
                    try SafetyRecordFile.write(merged, to: to)
                    try fm.removeItem(at: from)
                } else {
                    try fm.moveItem(at: from, to: to)
                    SafetyRecordFile.syncFolder(current)
                }
                SafetyRecordFile.syncFolder(legacy)
                adopted.append(name)
            } catch {
                continue
            }
        }
        for name in [episodeName, muteName] {
            SafetyRecordFile.remove(legacy.appendingPathComponent(name + ".tmp"))
        }
        if let left = try? fm.contentsOfDirectory(atPath: legacy.path), left.isEmpty {
            try? fm.removeItem(at: legacy)
        }
        return adopted
    }

    static func merge(name: String, legacy: Data, current: Data) -> Data {
        name == muteName ? mergedMutes(legacy: legacy, current: current) : mergedEpisode(legacy: legacy, current: current)
    }

    /// One record fits the slot. Either one makes the recovery stop Claude's dictation; the current folder's wins
    /// unless it is unreadable.
    static func mergedEpisode(legacy: Data, current: Data) -> Data {
        if (try? SafetyRecordCoding.decoder.decode(EpisodeRecord.self, from: current)) == nil,
           (try? SafetyRecordCoding.decoder.decode(EpisodeRecord.self, from: legacy)) != nil {
            return legacy
        }
        return current
    }

    /// Every device muted by either build stays on the list. For a device on both, the earlier record wins: it holds
    /// the volume or mute state from before any build touched the device.
    static func mergedMutes(legacy: Data, current: Data) -> Data {
        let old = try? SafetyRecordCoding.decoder.decode([MuteRecord].self, from: legacy)
        let new = try? SafetyRecordCoding.decoder.decode([MuteRecord].self, from: current)
        guard let old else { return current }
        guard let new else { return legacy }
        var byDevice: [String: MuteRecord] = [:]
        for record in old + new {
            if let seen = byDevice[record.deviceUID], seen.appliedAt <= record.appliedAt { continue }
            byDevice[record.deviceUID] = record
        }
        let merged = byDevice.values.sorted { ($0.appliedAt, $0.deviceUID) < ($1.appliedAt, $1.deviceUID) }
        return (try? SafetyRecordCoding.encoder.encode(merged)) ?? current
    }
}
