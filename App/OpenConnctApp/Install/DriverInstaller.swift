import Foundation
import Security

// MARK: - DriverInstaller
//
// The app carries the HAL plug-in inside its own bundle, but the plug-in only
// does anything once it sits in /Library/Audio/Plug-Ins/HAL, which needs an
// administrator. This is the whole of that mechanism.
//
// Why a one-shot prompt and not a privileged helper
// ------------------------------------------------
// The Apple-sanctioned route for privileged work is SMAppService: ship a helper
// daemon, register it, talk to it over XPC. It is the right answer when an app
// needs privilege *repeatedly* or *unattended*. This app needs it twice in its
// life — once at install, once per update — and always with the user watching.
//
// Paying for that with a permanently installed root daemon is a bad trade. The
// daemon outlives the app, runs whether or not anyone is using it, and exists
// to be asked to write into a system directory. Anything that can reach it
// inherits that. A one-shot authorization prompt leaves nothing behind: when
// the copy is finished there is no privileged component left to attack.
//
// AuthorizationExecuteWithPrivileges, which is what older code used for this,
// is not an option — deprecated since 10.7 and absent on Apple silicon.
//
// So: osascript, `do shell script … with administrator privileges`, which
// raises the standard system authentication panel and drops the privilege the
// moment the script exits.
//
// What is NOT done here
// ---------------------
// This type does not decide what is safe to install. It runs a fixed script
// that ships inside the bundle, and that script re-checks the driver's
// signature as root before copying anything. Validation done out here, in an
// unprivileged process, would prove nothing about what the privileged process
// then did with the result.

@MainActor
final class DriverInstaller: ObservableObject {

    enum State: Equatable {
        /// Installed, and the same version the app carries.
        case upToDate
        /// Nothing in /Library/Audio/Plug-Ins/HAL.
        case notInstalled
        /// Installed, but older than the copy in this app bundle.
        case outdated(installed: String, bundled: String)
        /// This build has no embedded driver, so there is nothing to offer.
        case unavailable
    }

    enum Failure: Error, LocalizedError, Equatable {
        case cancelled
        case noBundledDriver
        case script(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:       return nil
            case .noBundledDriver: return "This copy of the app does not include a driver to install."
            case .script(let m):   return m
            }
        }
    }

    @Published private(set) var state: State = .unavailable
    @Published private(set) var isInstalling = false
    /// Set when an attempt fails for a reason worth showing. Cancelling is not
    /// a failure and deliberately leaves this nil.
    @Published var lastError: String?

    private let installedPath = "/Library/Audio/Plug-Ins/HAL/OpenConnct.driver"

    init() {
        refresh()
    }

    // MARK: Status

    func refresh() {
        guard let bundled = bundledVersion else {
            state = .unavailable
            return
        }
        guard let installed = installedVersion else {
            state = .notInstalled
            return
        }
        // Numeric comparison, so 10 sorts after 9 rather than before it.
        if installed.compare(bundled, options: .numeric) == .orderedAscending {
            state = .outdated(installed: installed, bundled: bundled)
        } else {
            state = .upToDate
        }
    }

    /// True when the user could usefully be asked to do something.
    var needsAction: Bool {
        switch state {
        case .notInstalled, .outdated: return true
        case .upToDate, .unavailable:  return false
        }
    }

    private var bundledDriverPath: String? {
        let path = Bundle.main.bundlePath
            + "/Contents/Library/Audio/Plug-Ins/HAL/OpenConnct.driver"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private var bundledVersion: String? {
        bundledDriverPath.flatMap(Self.bundleVersion(at:))
    }

    private var installedVersion: String? {
        Self.bundleVersion(at: installedPath)
    }

    /// Read straight from the plist on disk rather than through `Bundle`.
    /// `Bundle(path:)` caches per path for the lifetime of the process, so
    /// after installing an update it would keep returning the version it saw
    /// first and the banner would never clear.
    private static func bundleVersion(at bundlePath: String) -> String? {
        let plist = bundlePath + "/Contents/Info.plist"
        guard let data = FileManager.default.contents(atPath: plist),
              let root = try? PropertyListSerialization
                .propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return root["CFBundleVersion"] as? String
    }

    // MARK: Install

    func install() async {
        guard !isInstalling else { return }
        isInstalling = true
        lastError = nil
        defer { isInstalling = false }

        do {
            try await Self.runPrivilegedInstall()
            refresh()
        } catch Failure.cancelled {
            // The user said no. That is an answer, not a fault.
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static func runPrivilegedInstall() async throws {
        guard let script = Bundle.main.path(forResource: "install-driver", ofType: "sh") else {
            throw Failure.noBundledDriver
        }

        return try await withCheckedThrowingContinuation { continuation in
            // Off the main thread: the authentication panel is modal and can
            // sit there for as long as the user likes. Audio keeps running
            // either way — it is on its own realtime thread — but a beachballed
            // window while the panel is up looks like a crash.
            //
            // The two helpers below are `nonisolated` for exactly this reason.
            // Members of a @MainActor type are main-actor isolated even when
            // static, so without it this call would be hopping straight back to
            // the thread it is trying to keep free.
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try runOsascript(installing: script)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Printed by `install-driver.sh` as its final act. Must match the script.
    nonisolated private static let successSentinel = "OC_INSTALL_OK"

    nonisolated private static func runOsascript(installing script: String) throws {
        // Check our own seal before handing anything to root.
        //
        // This is not belt-and-braces. The script is only trustworthy because
        // it is sealed inside a signed bundle, and that seal is worth exactly
        // as much as somebody checking it. macOS checks the main executable at
        // launch, but altering a *resource* does not stop an already-trusted
        // app from starting, so without this a rewritten script would simply
        // run, as root, on the next click.
        //
        // What it does NOT do, and the comment that used to be here got this
        // wrong: it does not eliminate the race. We verify the bundle, then
        // hand osascript a *path*, and root opens that path afresh. Anything
        // able to write the file in between gets to choose what root runs. The
        // check cannot be moved inside the privileged side either — a swapped
        // script would just omit it.
        //
        // Closing that window properly means the file must not be writable by
        // the attacker in the first place, which is a question of where the app
        // lives, not of what this function does. Installed in /Applications it
        // takes an administrator to touch, and an administrator is already on
        // the other side of the prompt. Run from ~/Downloads or a USB stick it
        // does not, and this check narrows the attack from "edit a file" to
        // "win a race" rather than preventing it. That trade-off is documented
        // in SECURITY.md instead of being papered over here.
        try verifyOwnBundle()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")

        // The script's path is passed through the environment and read back
        // with `system attribute`, so it never becomes part of the AppleScript
        // source text. Building that text by concatenation is how this kind of
        // code goes wrong: the path is user-influenced — anyone can rename or
        // relocate the app — and a stray quote in the name would either break
        // the script or, worse, extend the command that ends up running as
        // root. With the value fetched at runtime there is no source text to
        // escape and nothing to inject into.
        //
        // It still lands in a shell, so it is shell-quoted on the way in.
        var environment = ProcessInfo.processInfo.environment
        environment["OC_INSTALL_COMMAND"] = shellQuoted(script)
        process.environment = environment

        process.arguments = [
            "-e", #"do shell script (system attribute "OC_INSTALL_COMMAND") with administrator privileges"#
        ]

        let errorPipe = Pipe()
        let outputPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = outputPipe

        try process.run()

        // Both pipes are drained concurrently, then we wait.
        //
        // Reading one to EOF and then the other is the classic deadlock: if the
        // child filled the pipe nobody is draining, it blocks on write while we
        // block on read, and neither ever finishes. This script only ever emits
        // a line or two, so it is not reachable today — but it is a trap left
        // lying in the code for whoever makes the script chattier later.
        let group = DispatchGroup()
        var errorData = Data()
        var outputData = Data()

        let queue = DispatchQueue(label: "audio.openconnct.installer.io", attributes: .concurrent)
        queue.async(group: group) {
            errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        }
        queue.async(group: group) {
            outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        }
        group.wait()
        process.waitUntilExit()

        guard process.terminationStatus != 0 else {
            // Exiting zero under `set -e` already implies the script reached its
            // end, so this is belt and braces — but it is free, and it upgrades
            // the claim from "some process exited cleanly" to "our script ran to
            // its last line". `contains` rather than a suffix or line match on
            // purpose: `do shell script` hands text back with AppleScript's own
            // line endings, and the script may have written advisory notes
            // alongside the sentinel.
            let output = String(decoding: outputData, as: UTF8.self)
            guard output.contains(Self.successSentinel) else {
                throw Failure.script("The installer did not report success.")
            }
            return
        }
        let message = String(decoding: errorData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if isUserCancellation(message) {
            throw Failure.cancelled
        }

        throw Failure.script(message.isEmpty
            ? "The installer exited with code \(process.terminationStatus)."
            : message)
    }

    /// AppleScript reports "user cancelled" as error number -128, and osascript
    /// prints it as a parenthesised code at the very end of the line:
    ///
    ///     execution error: User canceled. (-128)
    ///
    /// Matching the bare substring anywhere in the text is too loose. The
    /// message also carries the script's own diagnostics, which quote the app
    /// bundle's path — and that path is whatever the user called their folder.
    /// Somebody with the app in `~/build-128/` would have every genuine failure
    /// silently reclassified as "they clicked Cancel", leaving the banner with
    /// nothing to show and the install quietly not happening.
    nonisolated private static func isUserCancellation(_ message: String) -> Bool {
        message
            .split(whereSeparator: \.isNewline)
            .contains { $0.trimmingCharacters(in: .whitespaces).hasSuffix("(-128)") }
    }

    /// POSIX single-quoting: everything inside single quotes is literal, and a
    /// single quote itself is spliced in as `'\''`.
    nonisolated private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Validates this app bundle against its own signature, sealed resources
    /// included.
    ///
    /// Uses the Security framework rather than shelling out to `codesign`,
    /// because a check that can be defeated by putting a different `codesign`
    /// earlier on PATH is not a check.
    nonisolated private static func verifyOwnBundle() throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
                Bundle.main.bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode
        else {
            throw Failure.script("Could not read this app's own code signature.")
        }

        // The default validity check already covers the sealed resources, which
        // is the part that matters here; the extra flag makes it check every
        // slice of the universal binary rather than only the running one.
        let status = SecStaticCodeCheckValidity(
            code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil)

        guard status == errSecSuccess else {
            throw Failure.script(
                "This copy of OpenConnct has been modified since it was signed, "
                + "so its installer cannot be trusted with administrator rights. "
                + "Download a fresh copy. (code \(status))")
        }
    }
}
