import Foundation

/// Persists which input devices the user wants OpenConnect to use, keyed by
/// CoreAudio device UID.
///
/// Absence of a stored selection is meaningfully different from an empty one:
/// on first launch we have no idea which of the machine's inputs are the user's
/// microphones, so we bind them all and let them prune. Once the user has made
/// a choice — including deselecting everything — we honour it exactly.
struct DeviceSelectionStore {
    private let fileURL: URL

    init(filename: String = "devices.json") {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("OpenConnect", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent(filename)
    }

    func load() -> Set<String>? {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        return Set(decoded)
    }

    func save(_ uids: Set<String>) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(uids.sorted()) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
