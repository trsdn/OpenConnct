import Foundation

/// The one place that knows where OpenConnct keeps its files, and the one place
/// that knows the application used to be called something else.
///
/// The project was renamed from OpenConnect (the name was taken) to OpenConnct.
/// Application Support directories are named after the application, so without
/// this every existing installation would silently come back with no channel
/// settings and no device selection — indistinguishable, from the user's side,
/// from the update having reset everything.
enum AppSupport {
    private static let directoryName = "OpenConnct"
    private static let previousDirectoryName = "OpenConnect"

    /// The application's Application Support directory, created if needed, and
    /// carried over from the previous name on first run after the rename.
    ///
    /// Computed once. The migration is a filesystem move, and repeating the
    /// check on every store construction would be wasted work for the entire
    /// life of the application after the first launch.
    static let directory: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let current = base.appendingPathComponent(directoryName, isDirectory: true)

        // Only when there is nothing at the new name. If both exist the new one
        // wins: it is either a fresh install that has already been used, or a
        // migration that has already happened, and in neither case may older
        // data be allowed to overwrite it.
        if !fm.fileExists(atPath: current.path) {
            let previous = base.appendingPathComponent(previousDirectoryName, isDirectory: true)
            if fm.fileExists(atPath: previous.path) {
                // Move rather than copy, so a half-finished migration cannot be
                // repeated against stale data, and so the outcome is visible if
                // the user goes looking.
                try? fm.moveItem(at: previous, to: current)
            }
        }

        try? fm.createDirectory(at: current, withIntermediateDirectories: true)
        return current
    }()
}
