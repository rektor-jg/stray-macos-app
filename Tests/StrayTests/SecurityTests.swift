import XCTest
@testable import Stray

/// Testy regresyjne po przeglądzie bezpieczeństwa z 18.08.2026.
/// Każde znalezisko ma tu własny test, żeby nie wróciło niezauważone.
final class SecurityTests: XCTestCase {

    /// Realistyczne linie poleceń z sekretami. Wartości są zmyślone,
    /// ale ich kształt odpowiada prawdziwym tokenom.
    private let leaky = [
        "node deploy.js --token=ghp_AbCdEf1234567890XyZ --env prod",
        "npx wrangler deploy --api-key sk-ant-api03-NOTAREALSECRETVALUE99",
        "python train.py --hf-token hf_QwErTyUiOpAsDfGhJkL",
        "curl -H 'Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9'",
        "aws s3 sync . s3://bucket --profile AKIAIOSFODNN7EXAMPLE",
        "node index.js --password hunter2secretvalue --port 3000",
        "API_KEY=sk_live_51H8xQwErTyUiOpAsDf node server.js",
        "npm publish --token npm_aBcDeFgHiJkLmNoPqRsTuVwXyZ012345",
        "deploy --access-token glpat-XyZaBcDeFgHiJkLmNoPq",
    ]

    /// Fragmenty, które NIE mogą przetrwać maskowania.
    private let mustNotSurvive = [
        "AbCdEf1234567890XyZ", "NOTAREALSECRETVALUE99", "QwErTyUiOpAsDfGhJkL",
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9", "IOSFODNN7EXAMPLE",
        "hunter2secretvalue", "51H8xQwErTyUiOpAsDf",
        "aBcDeFgHiJkLmNoPqRsTuVwXyZ012345", "XyZaBcDeFgHiJkLmNoPq",
    ]

    func testMaskerRemovesEveryKnownSecretShape() {
        for command in leaky {
            let masked = SecretMasker.mask(command)
            for secret in mustNotSurvive where command.contains(secret) {
                XCTAssertFalse(masked.contains(secret),
                               "sekret przetrwał maskowanie w: \(command)\n  → \(masked)")
            }
        }
    }

    func testMaskerKeepsCommandReadable() {
        let masked = SecretMasker.mask("node deploy.js --token=ghp_AbCdEf1234567890XyZ --env prod")
        XCTAssertTrue(masked.contains("node deploy.js"), "nazwa polecenia ma zostać czytelna")
        XCTAssertTrue(masked.contains("--env prod"), "reszta argumentów ma zostać czytelna")
    }

    /// ZNALEZISKO: "Ignoruj ten proces" zapisywało pierwsze cztery tokeny komendy
    /// do UserDefaults BEZ maskowania. To plik plist na dysku, który przeżywa aplikację
    /// i którego użytkownik nigdy nie ogląda — sekret zostawał tam na zawsze.
    func testIgnoreListNeverPersistsSecrets() {
        let key = "stray.ignoredCommands"
        let backup = UserDefaults.standard.stringArray(forKey: key)
        defer { UserDefaults.standard.set(backup, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)

        for command in leaky { Whitelist.ignore(command) }

        let persisted = (UserDefaults.standard.stringArray(forKey: key) ?? []).joined(separator: " ")
        for secret in mustNotSurvive {
            XCTAssertFalse(persisted.contains(secret),
                           "sekret zapisany na dysk w UserDefaults: \(secret)")
        }
    }

    func testIgnoreStillMatchesAfterTokenRotation() {
        let key = "stray.ignoredCommands"
        let backup = UserDefaults.standard.stringArray(forKey: key)
        defer { UserDefaults.standard.set(backup, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)

        // Maskowanie sprowadza token do stałej, więc rotacja klucza nie gubi wyboru użytkownika.
        Whitelist.ignore("node deploy.js --token=ghp_AAAAAAAAAAAAAAAAAAAA --env prod")
        XCTAssertTrue(
            Whitelist.isUserIgnored("node deploy.js --token=ghp_BBBBBBBBBBBBBBBBBBBB --env prod"),
            "ignorowanie ma przeżyć rotację tokenu")
    }

    /// Maskowanie musi być liniowe — narzędzie powstałe z powodu catastrophic backtrackingu
    /// nie może samo się na nim zawiesić.
    func testMaskerStaysLinearOnHostileInput() {
        for hostile in [String(repeating: "sk-", count: 50_000),
                        String(repeating: "Bearer ", count: 20_000),
                        String(repeating: "--token=", count: 20_000)] {
            let started = Date()
            _ = SecretMasker.mask(hostile)
            XCTAssertLessThan(Date().timeIntervalSince(started), 2.0,
                              "maskowanie musi być liniowe")
        }
    }

    /// ZNALEZISKO: piaskownica kasowania musi odrzucać przejścia w górę drzewa.
    func testDeletionSandboxRejectsTraversal() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for hostile in [
            "\(home)/.claude/../../../etc/passwd",
            "\(home)/.claude/../.ssh",
            "\(home)/.npm/../../../../System/Library",
            "\(home)/.cache/../../../../private/var/db",
            "/etc/passwd", "/", "/System",
        ] {
            let item = DiskItem(path: hostile, displayName: "hostile", bytes: 1,
                                category: .agentData,
                                confidenceRaw: Confidence.measured.rawValue,
                                safeToDelete: true, note: "", suggestedCommand: nil)
            XCTAssertThrowsError(try DiskActions.validate(item),
                                 "piaskownica musi odrzucić: \(hostile)")
        }
    }

    /// ZNALEZISKO: między skanem a kliknięciem "Ubij" proces mógł umrzeć,
    /// a jądro mogło nadać ten sam PID czemuś innemu.
    func testKillGuardRejectsMismatchedStartTime() {
        let me = getpid()
        XCTAssertFalse(
            ProcessActions.startMatches(pid: me, expected: Date(timeIntervalSince1970: 0)),
            "inny czas startu = inny proces, nie wolno go tknąć")
        XCTAssertEqual(ProcessActions.terminateTree(pid: me,
                                                    expectedStart: Date(timeIntervalSince1970: 0)),
                       0, "strażnik musi zatrzymać ubijanie zanim cokolwiek zrobi")
    }

    func testKillGuardAcceptsMatchingStartTime() {
        let me = getpid()
        guard let (_, _, _, _, started) = ProcScanner.sample(me, at: Date()) else {
            return XCTFail("nie da się odczytać własnego procesu")
        }
        XCTAssertTrue(ProcessActions.startMatches(pid: me, expected: started))
    }

    /// ZNALEZISKO: dopasowanie nazwy agenta szło po przedrostku, więc usługa systemowa
    /// Apple `CursorUIViewService` (od kursora tekstowego, nie od edytora Cursor)
    /// była liczona jako proces AI i zawyżała ślad.
    func testAgentMatchingRejectsSystemServices() {
        XCTAssertFalse(AgentSignatures.isAgent("CursorUIViewService"),
                       "usługa systemowa Apple to nie agent AI")
        XCTAssertFalse(AgentSignatures.isAgent(
            name: "CursorUIViewService",
            command: "/System/Library/PrivateFrameworks/TextInputUIMacHelper.framework/"
                   + "Versions/A/XPCServices/CursorUIViewService.xpc/Contents/MacOS/CursorUIViewService"))
        // cokolwiek spod /System/ jest odrzucane niezależnie od nazwy
        XCTAssertFalse(AgentSignatures.isAgent(name: "claude",
                                               command: "/System/Library/CoreServices/claude"))
    }

    func testAgentMatchingStillCatchesRealAgents() {
        for name in ["claude", "claude.exe", "Claude", "codex", "cursor", "aider"] {
            XCTAssertTrue(AgentSignatures.isAgent(name), "\(name) musi być rozpoznane")
        }
        XCTAssertTrue(AgentSignatures.isAgent("Claude Helper (Renderer)"),
                      "procesy pomocnicze aplikacji desktopowej też się liczą")
        XCTAssertTrue(AgentSignatures.isAgent(
            name: "claude.exe",
            command: "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"))
    }

    /// Aplikacja nie ma prawa wychodzić do sieci — czyta cudze linie poleceń,
    /// więc każde połączenie byłoby kanałem wycieku.
    func testNoNetworkSymbolsLinked() throws {
        let binary = ".build/debug/StrayPackageTests.xctest/Contents/MacOS/StrayPackageTests"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: binary), "brak zbudowanej binarki")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/nm")
        task.arguments = ["-u", binary]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try task.run()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        task.waitUntilExit()
        for forbidden in ["_CFURLSessionCreate", "_connect$", "NSURLConnection"] {
            XCTAssertFalse(out.contains(forbidden), "znaleziono symbol sieciowy: \(forbidden)")
        }
    }
}
