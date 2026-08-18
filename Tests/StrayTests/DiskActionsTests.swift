import XCTest
@testable import Stray

/// Testy barier kasowania. Błąd w tym pliku oznacza utratę cudzych danych,
/// więc każda bariera ma własny test, a nie jeden test „ogólnie działa".
final class DiskActionsTests: XCTestCase {

    private var sandbox: URL!

    override func setUpWithError() throws {
        // ~/.cache jest jednym z dozwolonych korzeni, więc testy działają
        // w tej samej piaskownicy co produkcja — a nie obok niej.
        sandbox = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/stray-tests-\(getpid())")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func item(path: String, safe: Bool = true,
                      category: DiskCategory = .agentData, bytes: UInt64 = 1024) -> DiskItem {
        DiskItem(path: path, displayName: "test", bytes: bytes, category: category,
                 confidenceRaw: Confidence.measured.rawValue, safeToDelete: safe,
                 note: "", suggestedCommand: nil)
    }

    // MARK: - bariera 1: tylko oznaczone jako bezpieczne

    func testRefusesItemNotMarkedSafe() {
        let target = sandbox.appendingPathComponent("x")
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        XCTAssertThrowsError(try DiskActions.validate(item(path: target.path, safe: false))) {
            guard case DiskActionError.notDeletable = $0 else {
                return XCTFail("zła przyczyna: \($0)")
            }
        }
    }

    // MARK: - bariera 2: piaskownica ścieżek

    func testRefusesPathOutsideSandbox() {
        // Katalog istnieje i jest „bezpieczny", ale leży poza dozwolonymi korzeniami.
        let outside = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents").path
        XCTAssertThrowsError(try DiskActions.validate(item(path: outside))) {
            guard case DiskActionError.outsideSandbox = $0 else {
                return XCTFail("zła przyczyna: \($0)")
            }
        }
    }

    func testRefusesSystemPaths() {
        for path in ["/System/Library", "/usr/bin", "/"] {
            XCTAssertThrowsError(try DiskActions.validate(item(path: path)),
                                 "nie wolno tknąć \(path)")
        }
    }

    // MARK: - bariera 3: dowiązania

    func testRefusesSymlink() throws {
        let real = sandbox.appendingPathComponent("real")
        let link = sandbox.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertThrowsError(try DiskActions.validate(item(path: link.path))) {
            guard case DiskActionError.symlink = $0 else { return XCTFail("zła przyczyna: \($0)") }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.path),
                      "cel dowiązania musi pozostać nietknięty")
    }

    // MARK: - bariera 4: martwy artefakt musi być nadal martwy

    func testRefusesDeadArtifactWhoseProjectReturned() throws {
        let derived = sandbox.appendingPathComponent("Runner-abc")
        try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
        // WorkspacePath wskazuje na katalog, który ISTNIEJE — projekt wrócił
        let plist: [String: Any] = ["WorkspacePath": sandbox.path]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: derived.appendingPathComponent("info.plist"))

        XCTAssertThrowsError(
            try DiskActions.validate(item(path: derived.path, category: .deadArtifact))
        ) {
            guard case DiskActionError.projectCameBack = $0 else {
                return XCTFail("zła przyczyna: \($0)")
            }
        }
    }

    func testAllowsDeadArtifactWhoseProjectIsReallyGone() throws {
        let derived = sandbox.appendingPathComponent("Runner-def")
        try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
        let plist: [String: Any] = ["WorkspacePath": "/nie/ma/takiej/sciezki/App.xcworkspace"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: derived.appendingPathComponent("info.plist"))

        XCTAssertNoThrow(try DiskActions.validate(item(path: derived.path, category: .deadArtifact)))
    }

    // MARK: - ochrona trwającej sesji

    func testFreshDirectoryIsNotStale() throws {
        let fresh = sandbox.appendingPathComponent("active-session")
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        XCTAssertFalse(DiskActions.isStale(fresh.path),
                       "katalog tknięty przed chwilą należy do trwającej sesji")
    }

    func testOldDirectoryIsStale() throws {
        let old = sandbox.appendingPathComponent("old-session")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-48 * 3600)], ofItemAtPath: old.path)
        XCTAssertTrue(DiskActions.isStale(old.path))
    }

    /// Regresja z życia: w chwili pisania tego kodu w katalogu scratchpadów leżał
    /// katalog sesji zmodyfikowany 37 minut wcześniej — czyli trwającej.
    func testScratchpadRootDetection() {
        XCTAssertTrue(DiskActions.isScratchpadRoot("/private/tmp/claude-501"))
        XCTAssertFalse(DiskActions.isScratchpadRoot("/private/tmp/claude-501/-Users-jakubgora"),
                       "podkatalog sesji to nie korzeń — kasowanie idzie po dzieciach")
    }

    /// Regresja z próby na sucho: `standardizingPath` zamieniał `/private/tmp` na `/tmp`,
    /// przez co piaskownica odrzucała katalog scratchpadów, który sama wskazała jako
    /// bezpieczny do usunięcia.
    func testScratchpadRootPassesSandbox() throws {
        let root = "/private/tmp/claude-501"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: root),
                          "brak katalogu scratchpadów na tej maszynie")
        XCTAssertNoThrow(try DiskActions.validate(item(path: root)),
                         "katalog scratchpadów musi przechodzić piaskownicę")
    }

    func testNormalizeUnifiesTmpForms() {
        XCTAssertEqual(DiskActions.normalize("/tmp/claude-501"),
                       DiskActions.normalize("/private/tmp/claude-501"))
    }

    func testScratchpadRootDetectionAcrossTmpForms() {
        XCTAssertTrue(DiskActions.isScratchpadRoot("/tmp/claude-501"))
        XCTAssertTrue(DiskActions.isScratchpadRoot("/private/tmp/claude-501"))
        XCTAssertFalse(DiskActions.isScratchpadRoot("/private/tmp/claude-501/-Users-jakubgora"))
    }

    // MARK: - faktyczne usunięcie

    func testPermanentDeleteRemovesAndReportsBytes() throws {
        let victim = sandbox.appendingPathComponent("junk")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 40_000).write(to: victim.appendingPathComponent("blob.bin"))

        let freed = try DiskActions.deletePermanently(item(path: victim.path, bytes: 40_000))
        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path))
        XCTAssertEqual(freed, 40_000)
    }

    func testValidateRejectsVanishedItem() {
        XCTAssertThrowsError(
            try DiskActions.validate(item(path: sandbox.appendingPathComponent("brak").path))
        ) {
            guard case DiskActionError.vanished = $0 else { return XCTFail("zła przyczyna: \($0)") }
        }
    }
}
