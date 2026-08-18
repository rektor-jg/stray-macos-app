import Foundation

/// Skan dyskowy. Zmierzone: `du -sk` na 25 GB katalogu DerivedData trwa ~3 s,
/// więc to jest operacja na żądanie i raz na dobę w tle — nigdy w pętli próbkowania.
enum DiskScanner {

    /// Ścieżki, których obecność zdradza, że katalog roboczy należał do agenta.
    private static let agentPathMarkers = [
        "/scratchpad/", "/.claude/worktrees/", "/claude-",
        "/.codex/", "/.cursor/",
    ]

    /// Pliki, których obecność w repo sugeruje, że pracował tam agent.
    private static let agentProjectMarkers = ["CLAUDE.md", ".claude", ".cursor", "AGENTS.md"]

    static func scan(progress: (@Sendable (String) -> Void)? = nil) -> DiskReport {
        let started = Date()
        var report = DiskReport()
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // 1. Katalogi należące wprost do agentów — pomiar bezpośredni.
        progress?(L("disk.stage.agents"))
        let agentDirs: [(String, String, Bool, String)] = [
            ("\(home)/.claude/projects", "~/.claude/projects", false,
             L("disk.note.transcripts")),
            // Kopie plików sprzed edycji to dane użytkownika, nie cache — na nich stoi
            // możliwość cofnięcia zmian, więc nie wchodzą do "posprzątaj wszystko".
            ("\(home)/.claude/file-history", "~/.claude/file-history", false,
             L("disk.note.filehistory")),
            ("\(home)/.claude/image-cache", "~/.claude/image-cache", true, L("disk.note.imagecache")),
            ("\(home)/.codex", "~/.codex", false, L("disk.note.codex")),
            (FileMeasure.scratchpadRoot, L("disk.name.scratchpads"), true,
             L("disk.note.scratchpads")),
        ]
        let agentSizes = FileMeasure.sizes(agentDirs.map(\.0))
        for (path, name, safe, note) in agentDirs {
            guard let bytes = agentSizes[path], bytes > 0 else { continue }
            report.items.append(DiskItem(
                path: path, displayName: name, bytes: bytes,
                category: .agentData, confidenceRaw: Confidence.measured.rawValue,
                safeToDelete: safe, note: note,
                suggestedCommand: safe ? "rm -rf \(path)/*" : nil))
        }

        // 2. DerivedData — po katalogu na projekt, z weryfikacją, czy projekt jeszcze istnieje.
        progress?(L("disk.stage.derived"))
        report.items.append(contentsOf: scanDerivedData(home: home))

        // 3. Cache pakietów — wywnioskowane. Nie da się rozdzielić, ile z tego
        //    wynikło z pracy agenta, a ile z własnych `npm install`.
        progress?(L("disk.stage.caches"))
        let caches: [(String, String, String?)] = [
            ("\(home)/.npm/_cacache", L("disk.name.npm"), "npm cache verify"),
            ("\(home)/Library/pnpm/store", L("disk.name.pnpm"), "pnpm store prune"),
            ("\(home)/.cache", "~/.cache", nil),
        ]
        let cacheSizes = FileMeasure.sizes(caches.map(\.0))
        for (path, name, cmd) in caches {
            guard let bytes = cacheSizes[path], bytes > 0 else { continue }
            report.items.append(DiskItem(
                path: path, displayName: name, bytes: bytes,
                category: .packageCache, confidenceRaw: Confidence.inferred.rawValue,
                safeToDelete: cmd != nil,
                note: L("disk.note.cache"),
                suggestedCommand: cmd))
        }

        // 4. node_modules — z rozróżnieniem, czy w repo są ślady agenta.
        progress?(L("disk.stage.modules"))
        report.items.append(contentsOf: scanNodeModules(home: home))

        report.durationSeconds = Date().timeIntervalSince(started)
        report.scannedAt = Date()
        report.items.sort { $0.bytes > $1.bytes }
        return report
    }

    // MARK: - DerivedData

    private static func scanDerivedData(home: String) -> [DiskItem] {
        let root = "\(home)/Library/Developer/Xcode/DerivedData"
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return [] }

        // Wszystkie podkatalogi mierzone równolegle — `du` czeka na dysk, nie na CPU,
        // więc to jest różnica rzędu wielkości, a nie kosmetyka.
        let dirs = entries.compactMap { entry -> String? in
            let dir = "\(root)/\(entry)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { return nil }
            return dir
        }
        let sizes = FileMeasure.sizes(dirs)

        var items: [DiskItem] = []
        for dir in dirs {
            let entry = (dir as NSString).lastPathComponent
            guard let bytes = sizes[dir], bytes > 1_048_576 else { continue }

            let workspace = FileMeasure.workspacePath(plist: "\(dir)/info.plist")
            let projectGone = workspace.map { !fm.fileExists(atPath: $0) } ?? false
            let fromAgent = workspace.map { path in
                agentPathMarkers.contains { path.contains($0) }
            } ?? false

            if projectGone {
                // Dyskowy odpowiednik PPID == 1: artefakt przeżył swój projekt.
                items.append(DiskItem(
                    path: dir, displayName: entry.split(separator: "-").first.map(String.init) ?? entry,
                    bytes: bytes, category: .deadArtifact,
                    confidenceRaw: (fromAgent ? Confidence.traced : .inferred).rawValue,
                    safeToDelete: true,
                    note: fromAgent
                        ? L("disk.note.deadagent", shorten(workspace ?? "", home))
                        : L("disk.note.dead", shorten(workspace ?? "", home)),
                    suggestedCommand: "rm -rf \"\(dir)\""))
            } else if fromAgent {
                items.append(DiskItem(
                    path: dir, displayName: entry.split(separator: "-").first.map(String.init) ?? entry,
                    bytes: bytes, category: .buildCache,
                    confidenceRaw: Confidence.traced.rawValue,
                    safeToDelete: false,
                    note: L("disk.note.agentbuild"),
                    suggestedCommand: nil))
            }
        }
        return items
    }


    // MARK: - node_modules

    private static func scanNodeModules(home: String) -> [DiskItem] {
        let fm = FileManager.default
        let roots = ["\(home)/Documents/Repos", "\(home)/Desktop", home]
        var seen = Set<String>()
        var items: [DiskItem] = []

        // Najpierw sama lista kandydatów (tanie sprawdzenie istnienia),
        // potem jeden równoległy pomiar na wszystkie naraz.
        var candidates: [(nm: String, project: String, candidate: String)] = []
        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries {
                let project = "\(root)/\(entry)"
                for candidate in [project, "\(project)/apps/mobile", "\(project)/apps/web"] {
                    let nm = "\(candidate)/node_modules"
                    guard !seen.contains(nm), fm.fileExists(atPath: nm) else { continue }
                    seen.insert(nm)
                    candidates.append((nm, project, candidate))
                }
            }
        }
        let moduleSizes = FileMeasure.sizes(candidates.map(\.nm))

        for (nm, project, candidate) in candidates {
            do {
                    guard let bytes = moduleSizes[nm], bytes > 50_000_000 else { continue }
                    let hasAgentTraces = agentProjectMarkers.contains {
                        fm.fileExists(atPath: "\(project)/\($0)")
                    }
                    items.append(DiskItem(
                        path: nm, displayName: shorten(candidate, home) + "/node_modules", bytes: bytes,
                        category: .nodeModules,
                        confidenceRaw: (hasAgentTraces ? Confidence.inferred : .inferred).rawValue,
                        safeToDelete: false,
                        note: hasAgentTraces
                            ? L("disk.note.nodemodules.agent")
                            : L("disk.note.nodemodules"),
                        suggestedCommand: nil))
            }
        }
        return items
    }

    // MARK: - pomiar

    private static func shorten(_ path: String, _ home: String) -> String {
        let p = path.replacingOccurrences(of: home, with: "~")
        return p.count > 60 ? "…" + String(p.suffix(58)) : p
    }
}
