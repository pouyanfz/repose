import Foundation
import CryptoKit

enum Hashing {
    /// Lowercase hex SHA-256 of the UTF-8 bytes of `text`.
    static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The part of a window title that tends to stay the same while the user
    /// works: the text after the last " - " or " <U+2014> " separator
    /// (hyphen or em dash, each surrounded by spaces). Examples:
    ///   "index.ts - myproject - Visual Studio Code"  ->  "Visual Studio Code"
    ///   "Inbox - Gmail - Google Chrome"               ->  "Google Chrome"
    ///   "~ <U+2014> zsh <U+2014> 120x40"              ->  "120x40"
    /// Titles without a separator are returned unchanged.
    static func stablePart(of title: String) -> String {
        let separators = [" - ", " \u{2014} "]
        var bestRange: Range<String.Index>?
        for separator in separators {
            if let range = title.range(of: separator, options: .backwards) {
                if let current = bestRange {
                    if range.lowerBound > current.lowerBound {
                        bestRange = range
                    }
                } else {
                    bestRange = range
                }
            }
        }
        guard let range = bestRange else { return title }
        return String(title[range.upperBound...])
    }

    /// Returns (fullTitleHash, stablePartHash), or (nil, nil) for an empty title.
    static func titleHashes(for title: String) -> (String?, String?) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, nil) }
        return (sha256Hex(trimmed), sha256Hex(stablePart(of: trimmed)))
    }
}
