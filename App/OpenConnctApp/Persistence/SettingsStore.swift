import Foundation

/// Persists per-device settings to Application Support as JSON, keyed by the
/// CoreAudio device UID so that a replugged microphone comes back exactly as the
/// user left it.
struct SettingsStore {
    private let fileURL: URL

    init(filename: String = "channels.json") {
        self.fileURL = AppSupport.directory.appendingPathComponent(filename)
    }

    func load() -> [String: ChannelSettings] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        guard let decoded = try? JSONDecoder().decode([String: ChannelSettings].self, from: data) else {
            return [:]
        }
        return decoded
    }

    func save(_ settings: [String: ChannelSettings]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        // Atomic so a crash mid-write cannot leave a truncated settings file.
        try? data.write(to: fileURL, options: .atomic)
    }
}
