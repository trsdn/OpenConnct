import Foundation

/// Shortening device names for the mixer's channel strips.
///
/// A strip is 80 pt wide and gives the name all 64 pt it has left after
/// padding — about nine characters. Device names run to sixteen or twenty, so
/// something has to go, and the question is only what.
///
/// The part that gets cut must not be the part that identifies the microphone.
/// That sounds obvious and was not what happened: middle truncation kept the
/// first characters, and the first characters are usually the manufacturer,
/// which is identical on every strip from that manufacturer and therefore tells
/// two channels apart not at all.
public enum ChannelLabels {

    /// Shortens a list of device names for display side by side.
    ///
    /// A leading word is dropped from a name when some other name in the list
    /// currently begins with the same word. The reasoning is narrow and worth
    /// stating: a word shared with another channel cannot distinguish this
    /// channel from that one, and against the channels that *don't* share it the
    /// rest of the name already does the work. So a shared leading word costs
    /// characters and buys nothing — in a view where every strip is visible at
    /// once, which is the only view this is used in.
    ///
    /// Applied repeatedly, so two shared words go the same way as one.
    ///
    /// A name is never reduced to nothing: the last remaining word always
    /// stays, even if it is shared. Two microphones of the same model do end up
    /// with the same label — but they had the same name to begin with, so no
    /// information was lost that the mixer ever had.
    ///
    /// Order is preserved and the result has the same count as the input, so
    /// callers can zip it back against their channels.
    ///
    /// - Parameter names: the full device names, in strip order.
    /// - Returns: the shortened names, in the same order.
    public static func shorten(_ names: [String]) -> [String] {
        // One channel has nothing to be distinguished from.
        guard names.count > 1 else { return names.map(trimmed) }

        var words = names.map { trimmed($0).split(separator: " ").map(String.init) }

        // Each pass drops at most one word per name, so the loop is bounded by
        // the longest name. `changed` is what actually ends it in practice.
        var changed = true
        while changed {
            changed = false

            // How many names currently begin with each first word. Built fresh
            // every pass, because dropping a word exposes a new one.
            var leadCount: [String: Int] = [:]
            for w in words {
                guard let first = w.first else { continue }
                leadCount[first.lowercased(), default: 0] += 1
            }

            for i in words.indices {
                // Never strip a name down to nothing. A name that is a single
                // word keeps it, shared or not.
                guard words[i].count > 1, let first = words[i].first else { continue }
                if leadCount[first.lowercased(), default: 0] > 1 {
                    words[i].removeFirst()
                    changed = true
                }
            }
        }

        return zip(names, words).map { original, w in
            // A name made only of spaces has no words left to join; fall back to
            // what we were given rather than showing an empty strip.
            w.isEmpty ? trimmed(original) : w.joined(separator: " ")
        }
    }

    private static func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
