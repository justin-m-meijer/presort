import Foundation

/// Leest Mail.app via AppleScript. Zo is er geen wachtwoord nodig: de gebruiker
/// is er al ingelogd. Prijs daarvoor is dat Mail moet draaien -- IMAP komt later
/// als tweede weg, voor wie Mail niet gebruikt.
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
                return "Mail gaf geen antwoord. \(m)"
            }
        }
    }

    let account: String
    let postvak: String

    private static let US = "\u{1F}"

    /// Zet vrije tekst om in een AppleScript-tekenreeks, aanhalingstekens en al.
    /// Account- en postvaknaam komen uit invoervelden: zonder dit breekt een naam
    /// met een aanhalingsteken of een backslash het hele script.
    static func asTekenreeks(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\\", with: "\\\\")
        t = t.replacingOccurrences(of: "\"", with: "\\\"")
        // Een echte regelovergang in een tekenreeks is een syntaxfout in AppleScript.
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
            throw Fout.scriptMislukt(String(data: fout, encoding: .utf8) ?? "onbekende fout")
        }
        return String(data: uit, encoding: .utf8) ?? ""
    }

    /// Metadata van de recentste berichten. Geen inhoud -- die wordt pas per bericht opgehaald.
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

    /// De inhoud van één bericht, ontdaan van opmaak en van wat je niet ziet.
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

/// Haalt de schuilplaatsen weg waar instructies zich in e-mail verstoppen:
/// opmaak, onzichtbare tekens, en eindeloze lengte.
enum Sanering {
    static func schoon(_ ruw: String, max: Int = 4000) -> String {
        var t = ruw
        if t.contains("<") && t.contains(">") {
            t = t.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        }
        t = t.precomposedStringWithCompatibilityMapping
        t = String(t.unicodeScalars.filter { s in
            if s == "\n" || s == "\t" { return true }
            // opmaak- en stuurtekens weg: zero-width spaties, bidi-overrides
            return !(s.properties.generalCategory == .format
                     || s.properties.generalCategory == .control
                     || s.properties.generalCategory == .privateUse)
        }.map(Character.init))
        t = t.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > max {
            t = String(t.prefix(max)) + "\n… (ingekort)"
        }
        return t
    }
}
