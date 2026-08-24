import Foundation

/// Reads Mail.app through AppleScript, so no password is needed: the user is already
/// signed in there. The price is that Mail has to be running -- IMAP may follow as a
/// second route for people who do not use Mail.
struct Postvak {
    struct Bericht: Identifiable, Hashable {
        let id: String
        let datum: String
        let afzender: String
        let onderwerp: String
        let gelezen: Bool
    }

    enum Fout: LocalizedError {
        case scriptMislukt(String)
        var errorDescription: String? {
            switch self {
            case .scriptMislukt(let m):
                return String(format: t("mail.error.noAnswer"), m)
            }
        }
    }

    let account: String
    let postvak: String

    private static let US = "\u{1F}"

    /// Turns free text into an AppleScript string literal, quotes and all. Account and
    /// mailbox names come from text fields: without this, a name containing a quote or a
    /// backslash breaks the whole script.
    static func asTekenreeks(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\\", with: "\\\\")
        t = t.replacingOccurrences(of: "\"", with: "\\\"")
        // A real line break inside a string literal is a syntax error in AppleScript.
        t = t.replacingOccurrences(of: "\r\n", with: "\\n")
        t = t.replacingOccurrences(of: "\n", with: "\\n")
        t = t.replacingOccurrences(of: "\r", with: "\\r")
        t = t.replacingOccurrences(of: "\t", with: "\\t")
        return "\"" + t + "\""
    }

    private static func osascript(_ script: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-"]
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe
        try p.run()
        inPipe.fileHandleForWriting.write(Data(script.utf8))
        inPipe.fileHandleForWriting.closeFile()
        let uit = outPipe.fileHandleForReading.readDataToEndOfFile()
        let fout = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw Fout.scriptMislukt(String(data: fout, encoding: .utf8) ?? t("mail.error.unknown"))
        }
        return String(data: uit, encoding: .utf8) ?? ""
    }

    /// Metadata of the most recent messages. No body text -- that is fetched per message.
    func recent(dagen: Int, limiet: Int) throws -> [Bericht] {
        let accountTekst = Postvak.asTekenreeks(account)
        let postvakTekst = Postvak.asTekenreeks(postvak)
        let script = """
        on isoDatum(d)
            set j to year of d
            set mnd to (month of d) as integer
            return (j as string) & "-" & my pad(mnd) & "-" & my pad(day of d) & "T" & \
                   my pad(hours of d) & ":" & my pad(minutes of d)
        end isoDatum
        on pad(n)
            if n < 10 then return "0" & (n as string)
            return n as string
        end pad

        set US to (ASCII character 31)
        set grens to (current date) - (\(dagen) * days)
        tell application "Mail"
            set acc to first account whose name is \(accountTekst)
            set mb to mailbox \(postvakTekst) of acc
            set berichten to (messages of mb whose date received ≥ grens)
            set uit to {}
            set n to count of berichten
            if n > \(limiet) then set n to \(limiet)
            repeat with i from 1 to n
                set m to item i of berichten
                try
                    set ond to subject of m
                on error
                    set ond to ""
                end try
                try
                    set afz to sender of m
                on error
                    set afz to ""
                end try
                set end of uit to ((id of m) as string) & US & my isoDatum(date received of m) & \
                    US & afz & US & ond & US & ((read status of m) as string)
            end repeat
        end tell
        set AppleScript's text item delimiters to linefeed
        set r to uit as string
        set AppleScript's text item delimiters to ""
        return r
        """
        return try Postvak.osascript(script).split(separator: "\n").compactMap { regel in
            let d = regel.components(separatedBy: Postvak.US)
            guard d.count >= 5 else { return nil }
            return Bericht(id: d[0], datum: d[1], afzender: d[2], onderwerp: d[3],
                           gelezen: d[4].lowercased() == "true")
        }
    }

    /// The body of one message, stripped of markup and of what you cannot see.
    func inhoud(van id: String) throws -> String {
        let accountTekst = Postvak.asTekenreeks(account)
        let postvakTekst = Postvak.asTekenreeks(postvak)
        let script = """
        tell application "Mail"
            set acc to first account whose name is \(accountTekst)
            set mb to mailbox \(postvakTekst) of acc
            set treffers to (messages of mb whose id is \(id))
            if (count of treffers) is 0 then return ""
            try
                return content of item 1 of treffers
            on error
                return ""
            end try
        end tell
        """
        return Sanering.schoon(try Postvak.osascript(script))
    }
}

/// Removes the hiding places instructions use in email: markup, invisible characters,
/// and unbounded length.
enum Sanering {
    static func schoon(_ ruw: String, max: Int = 4000) -> String {
        var tekst = ruw
        if tekst.contains("<") && tekst.contains(">") {
            tekst = tekst.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        }
        tekst = tekst.precomposedStringWithCompatibilityMapping
        tekst = String(tekst.unicodeScalars.filter { s in
            if s == "\n" || s == "\t" { return true }
            // drop formatting and control characters: zero-width spaces, bidi overrides
            return !(s.properties.generalCategory == .format
                     || s.properties.generalCategory == .control
                     || s.properties.generalCategory == .privateUse)
        }.map(Character.init))
        tekst = tekst.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        tekst = tekst.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        tekst = tekst.trimmingCharacters(in: .whitespacesAndNewlines)
        if tekst.count > max {
            tekst = String(tekst.prefix(max)) + t("mail.truncated")
        }
        return tekst
    }
}
