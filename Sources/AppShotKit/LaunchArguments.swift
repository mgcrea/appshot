import Foundation

/// Splits the one quoted string `--extra-args` carries into launch arguments.
///
/// It is a single string rather than a repeated option because every value in it
/// begins with `-`, and ArgumentParser would read those as flags of its own.
/// That leaves appshot to tokenize it, and the obvious `split(separator: " ")`
/// silently cannot express a value containing a space.
///
/// That is not a hypothetical gap. The arguments worth pinning for a capture are
/// exactly the ambient macOS defaults that decide how the app renders, and
/// several of them are space-separated plist values:
///
///     -AppleHighlightColor "0.65 0.79 0.94 Blue"
///     -AppleLanguages "(en, fr)"
///
/// Under a naive split those arrive as four and two separate arguments, the
/// launch silently takes something else, and the screenshot is wrong in a way
/// only a human comparing two runs would notice.
public enum LaunchArguments {

    /// Tokenizes on whitespace, honouring single and double quotes and
    /// backslash escapes.
    ///
    /// Quotes group rather than delimit — `-A"b c"d` is one token `Ab cd`, which
    /// is what every shell does and what anyone writing this string expects.
    /// An unterminated quote is not an error: it runs to the end of the string,
    /// which is the friendlier reading of an obvious typo and matches `sh`.
    public static func split(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasCurrent = false
        var quote: Character?
        var escaped = false

        for character in line {
            if escaped {
                current.append(character)
                hasCurrent = true
                escaped = false
                continue
            }

            // Inside single quotes a backslash is literal, as in sh — otherwise a
            // Windows-style path or a regex in an argument would lose characters.
            if character == "\\", quote != "'" {
                escaped = true
                hasCurrent = true
                continue
            }

            if let open = quote {
                if character == open {
                    quote = nil
                } else {
                    current.append(character)
                }
                hasCurrent = true
                continue
            }

            if character == "\"" || character == "'" {
                quote = character
                hasCurrent = true
                continue
            }

            if character.isWhitespace {
                if hasCurrent {
                    tokens.append(current)
                    current = ""
                    hasCurrent = false
                }
                continue
            }

            current.append(character)
            hasCurrent = true
        }

        // A trailing backslash is a literal backslash rather than a dropped
        // character: silently swallowing the last byte of an argument is the
        // failure mode this whole type exists to remove.
        if escaped { current.append("\\") }
        if hasCurrent { tokens.append(current) }
        return tokens
    }
}
