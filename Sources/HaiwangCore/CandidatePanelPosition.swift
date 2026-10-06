import Foundation

/// The top-left corner keeps a pinned window stable when a translation increases its height.
public struct CandidatePanelPosition: Codable, Equatable, Sendable {
    public var left: Double
    public var top: Double
    public var displayID: UInt32?

    public init(left: Double, top: Double, displayID: UInt32? = nil) {
        self.left = left
        self.top = top
        self.displayID = displayID
    }

    public static let storageKey = "candidate-panel-position-v1"

    public static func load(from defaults: UserDefaults) -> Self? {
        guard let data = defaults.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.left.isFinite, value.top.isFinite else { return nil }
        return value
    }

    public func save(to defaults: UserDefaults) {
        guard left.isFinite, top.isFinite,
              let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    public static func reset(in defaults: UserDefaults) { defaults.removeObject(forKey: storageKey) }
}
