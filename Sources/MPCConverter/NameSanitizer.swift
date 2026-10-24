import Foundation

enum NameSanitizer {
    /// Characters macOS, Windows/FAT32 and sampler file systems choke on.
    private static let illegal: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
    private static let trimSet = CharacterSet(charactersIn: " ._-")

    /// Clean a single file or folder name (no extension).
    /// - Normal: transliterate to ASCII, drop emoji/control chars, replace illegal chars with "_".
    /// - Strict: additionally allow only A–Z, a–z, 0–9, space, "-" and "_".
    static func clean(_ raw: String, strict: Bool) -> String {
        var s = raw.precomposedStringWithCanonicalMapping
        if let t = s.applyingTransform(.toLatin, reverse: false) { s = t }
        if let t = s.applyingTransform(.stripDiacritics, reverse: false) { s = t }
        let manual: [String: String] = ["ß": "ss", "æ": "ae", "Æ": "AE", "ø": "o", "Ø": "O",
                                        "đ": "d", "Đ": "D", "ł": "l", "Ł": "L", "œ": "oe", "Œ": "OE"]
        for (k, v) in manual { s = s.replacingOccurrences(of: k, with: v) }

        var out = ""
        for scalar in s.unicodeScalars {
            if scalar.isASCII {
                if scalar.value < 0x20 || scalar.value == 0x7F { continue }
                let c = Character(scalar)
                if strict {
                    let ok = c.isLetter || c.isNumber || c == " " || c == "-" || c == "_"
                    out.append(ok ? c : "_")
                } else {
                    out.append(illegal.contains(c) ? "_" : c)
                }
            } else if scalar.properties.isWhitespace {
                out.append(" ")
            }
            // any other non-ASCII leftovers (emoji, symbols) are dropped
        }

        out = out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: "_{2,}", with: "_", options: .regularExpression)
        out = out.trimmingCharacters(in: trimSet)
        return out.isEmpty ? "untitled" : out
    }

    /// Fit a stem (+ optional collision suffix) into the length limit. Limit excludes ".wav".
    static func fit(_ stem: String, suffix: String, maxLength: Int) -> String {
        guard maxLength > 0 else { return stem + suffix }
        let budget = max(1, maxLength - suffix.count)
        var cut = String(stem.prefix(budget))
        let trimmed = cut.trimmingCharacters(in: trimSet)
        if !trimmed.isEmpty { cut = trimmed }
        return cut + suffix
    }
}
