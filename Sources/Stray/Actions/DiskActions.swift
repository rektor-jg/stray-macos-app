import Foundation

enum DiskActionError: LocalizedError {
    case notDeletable(String)
    case outsideSandbox(String)
    case symlink(String)
    case vanished(String)
    case projectCameBack(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notDeletable(let p):    return "\(p): oznaczone jako niebezpieczne do usunięcia"
        case .outsideSandbox(let p):  return "\(p): poza dozwolonymi katalogami"
        case .symlink(let p):         return "\(p): dowiązanie symboliczne — nie ruszamy"
        case .vanished(let p):        return "\(p): już nie istnieje"
        case .projectCameBack(let p): return "\(p): projekt źródłowy znów istnieje"
        case .failed(let p):          return "\(p): system odmówił usunięcia"
        }
    }
}

/// Kasowanie z dysku.
///
/// Najniebezpieczniejszy moduł w całym projekcie: `kill` da się cofnąć restartem procesu,
/// skasowanego katalogu nie da się cofnąć niczym. Stąd cztery bariery, przez które
/// musi przejść każda pozycja, oraz Kosz zamiast `rm` jako domyślna droga.
enum DiskActions {

    /// Ile czasu bez modyfikacji musi minąć, żeby uznać katalog sesji za porzucony.
    ///
    /// Nie jest to ostrożność na zapas: w chwili pisania tego kodu w katalogu scratchpadów
    /// leżał katalog sesji zmodyfikowany 37 minut wcześniej — czyli TRWAJĄCEJ.
    /// Bez tego progu „posprzątaj scratchpady" wywaliłoby katalog roboczy spod aktywnej pracy.
    static let staleAfter: TimeInterval = 24 * 3600

    // MARK: - bariera 1: piaskownica ścieżek

    /// Normalizacja ścieżki do jednej postaci.
    ///
    /// `standardizingPath` zamienia `/private/tmp/...` na `/tmp/...`, ale tylko dla ścieżek,
    /// które istnieją — a `resolvingSymlinksInPath` ma tę samą asymetrię. Prefiks korzenia
    /// nie istnieje jako plik, więc obie funkcje zostawiały go w innej postaci niż ścieżkę
    /// pozycji i piaskownica odrzucała katalog, który sama wskazała jako bezpieczny.
    ///
    /// Dlatego sprowadzamy `/private/tmp` i `/private/var` do postaci krótkiej sami,
    /// deterministycznie i bez pytania systemu plików o cokolwiek.
    static func normalize(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        for prefix in ["/private/tmp/", "/private/var/", "/private/tmp", "/private/var"]
        where p.hasPrefix(prefix) {
            p = String(p.dropFirst("/private".count))
            break
        }
        return p
    }

    private static var allowedRoots: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/Library/Developer/Xcode/DerivedData/",
            "\(home)/.claude/",
            "\(home)/.codex/",
            "\(home)/.npm/",
            "\(home)/Library/pnpm/",
            "\(home)/.cache/",
            FileMeasure.scratchpadPrefix,
        ].map(normalize)
    }

    /// Wszystkie bariery naraz. Wołane tuż przed usunięciem, nie przy skanie —
    /// raport może mieć kilkanaście minut i świat mógł się w tym czasie zmienić.
    static func validate(_ item: DiskItem) throws {
        let fm = FileManager.default
        let path = normalize(item.path)

        // 1. tylko to, co skaner sam oznaczył jako bezpieczne
        guard item.safeToDelete else { throw DiskActionError.notDeletable(item.displayName) }

        // 2. tylko wewnątrz znanych katalogów — żadnych ścieżek z zewnątrz
        guard allowedRoots.contains(where: { path.hasPrefix($0) }) else {
            throw DiskActionError.outsideSandbox(item.displayName)
        }

        // 3. nigdy przez dowiązanie — inaczej kasujemy cel, nie link
        let attrs = try? fm.attributesOfItem(atPath: path)
        if let type = attrs?[.type] as? FileAttributeType, type == .typeSymbolicLink {
            throw DiskActionError.symlink(item.displayName)
        }
        guard fm.fileExists(atPath: path) else { throw DiskActionError.vanished(item.displayName) }

        // 4. martwy artefakt musi być nadal martwy — projekt mógł wrócić
        //    (odmontowany dysk, przywrócone repo, przełączony worktree)
        if item.category == .deadArtifact {
            if let workspace = FileMeasure.workspacePath(plist: "\(path)/info.plist"),
               fm.fileExists(atPath: workspace) {
                throw DiskActionError.projectCameBack(item.displayName)
            }
        }
    }

    // MARK: - usuwanie

    /// Do Kosza. Droga domyślna, bo odwracalna jednym kliknięciem.
    /// Na tym samym woluminie to zwykła zmiana nazwy, więc działa natychmiast nawet dla 12 GB.
    @discardableResult
    static func trash(_ item: DiskItem) throws -> UInt64 {
        try validate(item)
        return try remove(item) { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    /// Nieodwracalnie. Do wyboru tylko świadomie — miejsce wraca od razu,
    /// bez czekania na opróżnienie Kosza.
    @discardableResult
    static func deletePermanently(_ item: DiskItem) throws -> UInt64 {
        try validate(item)
        return try remove(item) { url in
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Wspólna ścieżka obu trybów. Katalog scratchpadów traktowany osobno:
    /// kasujemy tylko te podkatalogi, których nikt od doby nie tknął.
    private static func remove(_ item: DiskItem,
                               using operation: (URL) throws -> Void) throws -> UInt64 {
        if isScratchpadRoot(item.path) {
            return try removeStaleChildren(of: item.path, using: operation)
        }
        let url = URL(fileURLWithPath: item.path)
        do { try operation(url) } catch { throw DiskActionError.failed(item.displayName) }
        return item.bytes
    }

    static func isScratchpadRoot(_ path: String) -> Bool {
        let normalized = normalize(path)
        let prefix = normalize(FileMeasure.scratchpadPrefix)
        guard normalized.hasPrefix(prefix) else { return false }
        return !normalized.dropFirst(prefix.count).contains("/")
    }

    /// Zwraca bajty faktycznie zwolnione — a nie te, które obiecywał raport.
    private static func removeStaleChildren(of root: String,
                                            using operation: (URL) throws -> Void) throws -> UInt64 {
        let fm = FileManager.default
        var freed: UInt64 = 0
        for child in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let path = "\(root)/\(child)"
            guard isStale(path) else { continue }   // aktywna sesja zostaje nietknięta
            let size = (FileMeasure.size(path) ?? 0)
            do {
                try operation(URL(fileURLWithPath: path))
                freed += size
            } catch { continue }                    // jedna oporna pozycja nie przerywa reszty
        }
        return freed
    }

    static func isStale(_ path: String, now: Date = Date()) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attrs[.modificationDate] as? Date else { return false }
        return now.timeIntervalSince(modified) > staleAfter
    }

    /// Ile z danej pozycji da się realnie usunąć — dla scratchpadów to tylko część.
    static func deletableBytes(_ item: DiskItem) -> UInt64 {
        guard isScratchpadRoot(item.path) else { return item.bytes }
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: item.path)) ?? [])
            .map { "\(item.path)/\($0)" }
            .filter { isStale($0) }
            .reduce(UInt64(0)) { $0 + (FileMeasure.size($1) ?? 0) }
    }

    // MARK: - pomocnicze

}
