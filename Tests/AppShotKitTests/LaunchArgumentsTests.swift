import Foundation
import Testing

@testable import AppShotKit

/// Tokenizing `--extra-args`.
///
/// The case that matters is the space-carrying value. `--extra-args` is one
/// string because every argument in it starts with `-`, and the naive
/// `split(separator: " ")` this replaced could not express
/// `-AppleHighlightColor "0.65 0.79 0.94 Blue"` at all — it arrived as four
/// arguments, the launch quietly took something else, and the only symptom was a
/// screenshot that rendered differently on a different Mac.
struct LaunchArgumentsTests {

    @Test func plainArguments_splitOnWhitespace() {
        #expect(
            LaunchArguments.split("-ScreenshotMode YES -isProUnlocked YES")
                == ["-ScreenshotMode", "YES", "-isProUnlocked", "YES"])
    }

    @Test func emptyString_yieldsNoArguments() {
        #expect(LaunchArguments.split("") == [])
        #expect(LaunchArguments.split("   ") == [])
    }

    @Test func runsOfWhitespace_doNotProduceEmptyArguments() {
        // A Makefile line continuation indents the next line, so multiple spaces
        // and tabs are the normal case, not an edge case.
        #expect(LaunchArguments.split("-a  1 \t -b\n2") == ["-a", "1", "-b", "2"])
    }

    /// The whole reason this type exists.
    @Test func doubleQuotedValue_keepsItsSpaces() {
        #expect(
            LaunchArguments.split("-AppleHighlightColor \"0.65 0.79 0.94 Blue\"")
                == ["-AppleHighlightColor", "0.65 0.79 0.94 Blue"])
    }

    @Test func quotedPlistArray_survivesAsOneArgument() {
        #expect(
            LaunchArguments.split("-AppleLanguages \"(en, fr)\"")
                == ["-AppleLanguages", "(en, fr)"])
    }

    @Test func singleQuotesGroupToo() {
        #expect(LaunchArguments.split("-a 'one two' -b") == ["-a", "one two", "-b"])
    }

    /// Quotes group, they do not delimit — the same as every shell.
    @Test func quotesInsideAToken_groupRatherThanSplit() {
        #expect(LaunchArguments.split("-A\"b c\"d") == ["-Ab cd"])
    }

    @Test func anEmptyQuotedValue_isStillAnArgument() {
        // `-SomeFlag ""` means "pass an empty value", which is not the same as
        // passing nothing at all.
        #expect(LaunchArguments.split("-SomeFlag \"\"") == ["-SomeFlag", ""])
    }

    @Test func backslash_escapesTheNextCharacter() {
        #expect(LaunchArguments.split("-a one\\ two") == ["-a", "one two"])
        #expect(LaunchArguments.split("-a \\\"quoted\\\"") == ["-a", "\"quoted\""])
    }

    /// Inside single quotes a backslash is literal, as in sh, so a path or a
    /// regex passed as an argument does not quietly lose characters.
    @Test func backslashIsLiteralInsideSingleQuotes() {
        #expect(LaunchArguments.split("-a 'C:\\path'") == ["-a", "C:\\path"])
    }

    @Test func nestedOppositeQuotes_areLiteral() {
        #expect(LaunchArguments.split("-a \"it's\"") == ["-a", "it's"])
    }

    /// Not an error. An unterminated quote is an obvious typo, and running to the
    /// end of the string is both what sh does and the reading that loses least.
    @Test func unterminatedQuote_runsToTheEnd() {
        #expect(LaunchArguments.split("-a \"one two") == ["-a", "one two"])
    }

    /// A dropped final character is exactly the silent corruption this replaced.
    @Test func trailingBackslash_isKeptLiterally() {
        #expect(LaunchArguments.split("-a one\\") == ["-a", "one\\"])
    }
}
