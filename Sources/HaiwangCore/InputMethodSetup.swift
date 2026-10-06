import Foundation

public enum InputMethodSetupStep: Int, CaseIterable, Codable, Sendable {
    case install, enable, practice, translation
}

public struct InputMethodBuild: Equatable, Sendable {
    public let version: String
    public let build: String

    public init(version: String, build: String) {
        self.version = version
        self.build = build
    }

    public func isOlder(than other: Self) -> Bool {
        let comparison = version.compare(other.version, options: .numeric)
        return comparison == .orderedAscending
            || (comparison == .orderedSame && build.compare(other.build, options: .numeric) == .orderedAscending)
    }
}

/// A mode's default enabled flag alone cannot establish that the input method is usable.
public struct InputMethodSetupStatus: Equatable, Sendable {
    public var installed = false
    public var updateAvailable = false
    public var payloadAvailable = false
    public var queryAvailable = true
    public var registered = false
    public var parentEnabled = false
    public var modeEnabled = false
    public var selected = false

    public init() {}

    public var needsInstallation: Bool { !installed || updateAvailable }
    public var enabled: Bool { queryAvailable && registered && parentEnabled && modeEnabled }
    public var canPractice: Bool { installed && !needsInstallation && enabled }
    public var suggestedStep: InputMethodSetupStep {
        if needsInstallation { return .install }
        return enabled ? .practice : .enable
    }
}

/// Practice text remains in memory. Only a confirmed Chinese insertion from SailKing counts.
public struct InputMethodPractice: Equatable, Sendable {
    public private(set) var verified = false
    public var menuConfirmed = false

    public init() {}

    public mutating func recordInsertion(_ text: String, selectedSourceID: String?, marked: Bool, pasted: Bool = false) {
        guard !marked, !pasted, selectedSourceID == InputMethodPreferences.systemSourceID else { return }
        if text.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) || (0x20000...0x323AF).contains($0.value) }) {
            verified = true
        }
    }
}

public struct InputMethodOnboardingProgress: Codable, Equatable, Sendable {
    public private(set) var completed = false
    public private(set) var deferred = false
    private var schema = 1
    public static let storageKey = "input-method-onboarding-v1"

    public init() {}
    public var shouldPresentAutomatically: Bool { !completed && !deferred }

    public mutating func deferSetup() { deferred = true }

    @discardableResult
    public mutating func complete(status: InputMethodSetupStatus, practice: InputMethodPractice) -> Bool {
        guard status.canPractice, practice.menuConfirmed, practice.verified else { return false }
        completed = true
        deferred = false
        return true
    }

    public static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.schema == 1 else { return .init() }
        return value
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
