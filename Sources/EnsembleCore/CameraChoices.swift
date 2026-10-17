/// One entry of the camera choice shown in the menu panel and in Settings.
public struct CameraChoice: Equatable {
    /// What is stored when this entry is picked: nil is Automatic.
    public let name: String?
    public let isCurrent: Bool
    /// False only for a chosen camera that is not plugged in; Automatic always counts as connected.
    public let isConnected: Bool

    public var title: String { name ?? "Automatic" }
    /// Title plus the reason it cannot be used right now, if any.
    public var label: String { isConnected ? title : "\(title) (not connected)" }
}

public enum CameraChoices {
    /// Automatic first, then each connected camera in the order given. A chosen camera that is not connected is kept
    /// at the end so the setting never reads as something else, and is flagged as not connected.
    public static func rows(connected: [String], chosen: String?) -> [CameraChoice] {
        var rows = [CameraChoice(name: nil, isCurrent: chosen == nil, isConnected: true)]
        rows += connected.map { CameraChoice(name: $0, isCurrent: $0 == chosen, isConnected: true) }
        if let chosen, !connected.contains(chosen) {
            rows.append(CameraChoice(name: chosen, isCurrent: true, isConnected: false))
        }
        return rows
    }
}
