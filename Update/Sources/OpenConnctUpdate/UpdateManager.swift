import AppUpdater
import Foundation
import os.log

/// Checks GitHub Releases for a newer OpenConnct and installs it in place.
///
/// Backed by [AppUpdater](https://github.com/mxcl/AppUpdater). It only accepts
/// a release asset named exactly `OpenConnct-<semver>.dmg`, and only if the app
/// inside carries the same Developer ID Team ID, signing identifier and bundle
/// identifier as this one.
@MainActor
public final class UpdateManager: ObservableObject {
    public enum State: Equatable {
        case idle
        case checking
        case upToDate
        case downloading(version: String)
        case readyToInstall(version: String)
        case installing
        case failed(String)
        /// The audio engine was already stopped for the install, so the only
        /// way back to working audio is a relaunch.
        case installFailed(String)
    }

    @Published public private(set) var state: State = .idle

    @Published public var automaticChecksEnabled: Bool {
        didSet {
            guard automaticChecksEnabled != oldValue else { return }
            UserDefaults.standard.set(automaticChecksEnabled, forKey: Self.automaticChecksKey)
            if automaticChecksEnabled { startAutomaticChecks() } else { stopAutomaticChecks() }
        }
    }

    /// Runs right before the bundle is replaced, so the host can stop the audio
    /// engine instead of being killed mid-buffer.
    public var onWillInstall: (() -> Void)?

    private static let automaticChecksKey = "updates.automaticChecks.v1"
    private static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    private let updater = AppUpdater(owner: "trsdn", repo: "OpenConnct")
    private let log = Logger(subsystem: "audio.openconnct.app", category: "updates")
    private var preparedUpdate: PreparedUpdate?
    private var lastAutomaticCheck: Date?
    private var automaticCheckTask: Task<Void, Never>?

    public init() {
        automaticChecksEnabled = UserDefaults.standard.object(forKey: Self.automaticChecksKey) as? Bool ?? true
    }

    public var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    // MARK: - Automatic checks

    public func startAutomaticChecks() {
        automaticCheckTask?.cancel()
        guard automaticChecksEnabled else { return }
        // Wakes hourly but checks at most once a day: a Mac that sleeps through
        // the night would otherwise miss a plain 24-hour timer indefinitely.
        automaticCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self, self.isAutomaticCheckDue {
                    await self.check(userInitiated: false)
                }
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    public func stopAutomaticChecks() {
        automaticCheckTask?.cancel()
        automaticCheckTask = nil
    }

    private var isAutomaticCheckDue: Bool {
        guard let lastAutomaticCheck else { return true }
        return Date().timeIntervalSince(lastAutomaticCheck) >= Self.automaticCheckInterval
    }

    // MARK: - Check, install, dismiss

    /// Looks for a newer release and, if there is one, downloads and validates it
    /// so that installing is a single click.
    ///
    /// A failed background check stays in the log: being offline is not worth a
    /// banner over the mixer. A check the user asked for always answers.
    public func check(userInitiated: Bool) async {
        guard !isBusy, preparedUpdate == nil else { return }
        if userInitiated {
            state = .checking
        } else {
            lastAutomaticCheck = Date()
        }

        do {
            guard let update = try await updater.check() else {
                log.info("No update available")
                state = userInitiated ? .upToDate : .idle
                return
            }
            log.notice("Update available: \(update.version, privacy: .public)")
            state = .downloading(version: update.version)
            preparedUpdate = try await update.prepareInstallation()
            state = .readyToInstall(version: update.version)
        } catch is CancellationError {
            state = .idle
        } catch {
            log.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            state = userInitiated ? .failed(error.localizedDescription) : .idle
        }
    }

    /// Replaces the app and relaunches it. On success this never returns; the new
    /// process starts the audio engine again from a clean state.
    public func installAndRelaunch() async {
        guard let prepared = preparedUpdate else { return }
        preparedUpdate = nil
        state = .installing
        stopAutomaticChecks()
        onWillInstall?()

        do {
            try await prepared.installAndRelaunch()
        } catch {
            log.error("Install failed: \(error.localizedDescription, privacy: .public)")
            state = .installFailed(error.localizedDescription)
        }
    }

    /// Throws the downloaded update away. The next automatic check finds it again.
    public func dismiss() async {
        if let prepared = preparedUpdate {
            preparedUpdate = nil
            await prepared.discard()
        }
        state = .idle
    }
}
