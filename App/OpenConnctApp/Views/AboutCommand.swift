import AppKit
import SwiftUI

/// OpenConnct ▸ About OpenConnct.
///
/// The standard About panel already shows the name, version and the copyright
/// line from `Info.plist`. What it cannot show on its own is where the project
/// lives, so the credits carry the repository and issue tracker as links, read
/// from the same `Info.plist` keys a script can read without running the app.
struct AboutCommand: View {
    var body: some View {
        Button("About OpenConnct") {
            NSApp.orderFrontStandardAboutPanel(options: [.credits: Self.credits()])
        }
    }

    private static func credits() -> NSAttributedString {
        let info = Bundle.main.infoDictionary ?? [:]
        let repository = info["RepositoryURL"] as? String ?? ""
        let issues = info["IssueTrackerURL"] as? String ?? ""
        let licence = info["LicenseIdentifier"] as? String ?? ""

        let text = NSMutableAttributedString(
            string: "Source code and releases: ",
            attributes: [.font: NSFont.systemFont(ofSize: 11)])
        text.append(link(repository))
        text.append(NSAttributedString(string: "\nReport a problem: ", attributes: [.font: NSFont.systemFont(ofSize: 11)]))
        text.append(link(issues))
        text.append(NSAttributedString(
            string: "\nLicence: \(licence). The licences of the bundled packages are in "
                + "THIRD-PARTY-LICENSES.txt in the app's resources.",
            attributes: [.font: NSFont.systemFont(ofSize: 11)]))
        return text
    }

    private static func link(_ urlString: String) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11)]
        if let url = URL(string: urlString) { attributes[.link] = url }
        return NSAttributedString(string: urlString, attributes: attributes)
    }
}
