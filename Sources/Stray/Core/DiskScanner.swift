import Foundation

enum DiskCategory: String, Codable, Sendable, CaseIterable {
    case agentData      // własne katalogi agentów
    case deadArtifact   // artefakt po projekcie, którego już nie ma
    case buildCache     // DerivedData, gradle, CoreSimulator
    case packageCache   // npm, pnpm, yarn
    case nodeModules

    var label: String {
        switch self {
        case .agentData:    return L("disk.category.agentData")
        case .deadArtifact: return L("disk.category.deadArtifact")
        case .buildCache:   return L("disk.category.buildCache")
        case .packageCache: return L("disk.category.packageCache")
        case .nodeModules:  return L("disk.category.nodeModules")
        }
    }
}

struct DiskItem: Codable, Sendable, Identifiable {
    let path: String
    let displayName: String
    let bytes: UInt64
    let category: DiskCategory
    let confidenceRaw: Int
    let safeToDelete: Bool
    let note: String
    let suggestedCommand: String?

    var id: String { path }
    var confidence: Confidence { Confidence(rawValue: confidenceRaw) ?? .inferred }
}

struct DiskReport: Codable, Sendable {
    var items: [DiskItem] = []
    var scannedAt: Date = Date()
    var durationSeconds: Double = 0

    func total(_ confidence: Confidence) -> UInt64 {
        items.filter { $0.confidence == confidence }.reduce(0) { $0 + $1.bytes }
    }
    var reclaimable: UInt64 { items.filter(\.safeToDelete).reduce(0) { $0 + $1.bytes } }
    var grandTotal: UInt64 { items.reduce(0) { $0 + $1.bytes } }

    func byCategory() -> [(DiskCategory, UInt64)] {
        DiskCategory.allCases
            .map { cat in (cat, items.filter { $0.category == cat }.reduce(0) { $0 + $1.bytes }) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
    }
}

/// Skan dyskowy. Zmierzone: `du -sk` na 25 GB katalogu DerivedData trwa ~3 s,
/// więc to jest operacja na żądanie i raz na dobę w tle — nigdy w pętli próbkowania.
enum DiskScanner {

    /// Ścieżki, których obecność zdradza, że katalog roboczy należał do agenta.
    private static let agentPathMarkers = [
        "/scratchpad/", "/.claude/worktrees/", "/claude-501/", "/claude-",
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
        for (path, name, safe, note) in [
            ("\(home)/.claude/projects", "~/.claude/projects", false,
             L("disk.note.transcripts")),
            // Kopie plików sprzed edycji to dane użytkownika, nie cache — na nich stoi
            // możliwość cofnięcia zmian, więc nie wchodzą do "posprzątaj wszystko".
            ("\(home)/.claude/file-history", "~/.claude/file-history", false,
             L("disk.note.filehistory")),
            ("\(home)/.claude/image-cache", "~/.claude/image-cache", true, L("disk.note.imagecache")),
            ("\(home)/.codex", "~/.codex", false, L("disk.note.codex")),
            ("/private/tmp/claude-501", L("disk.name.scratchpads"), true,
             L("disk.note.scratchpads")),
        ] {
            guard let bytes = size(of: path), bytes > 0 else { continue }
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
        for (path, name, cmd) in [
            ("\(home)/.npm/_cacache", L("disk.name.npm"), "npm cache verify"),
            ("\(home)/Library/pnpm/store", L("disk.name.pnpm"), "pnpm store prune"),
            ("\(home)/.cache", "~/.cache", nil),
        ] as [(String, String, String?)] {
            guard let bytes = size(of: path), bytes > 0 else { continue }
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

        var items: [DiskItem] = []
        for entry in entries {
            let dir = "\(root)/\(entry)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue,
                  let bytes = size(of: dir), bytes > 1_048_576 else { continue }

            let workspace = workspacePath(plist: "\(dir)/info.plist")
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

    private static func workspacePath(plist: String) -> String? {
        guard let data = FileManager.default.contents(atPath: plist),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = obj as? [String: Any] else { return nil }
        return dict["WorkspacePath"] as? String
    }

    // MARK: - node_modules

    private static func scanNodeModules(home: String) -> [DiskItem] {
        let fm = FileManager.default
        let roots = ["\(home)/Documents/Repos", "\(home)/Desktop", home]
        var seen = Set<String>()
        var items: [DiskItem] = []

        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries {
                let project = "\(root)/\(entry)"
                for candidate in [project, "\(project)/apps/mobile", "\(project)/apps/web"] {
                    let nm = "\(candidate)/node_modules"
                    guard !seen.contains(nm), fm.fileExists(atPath: nm),
                          let bytes = size(of: nm), bytes > 50_000_000 else { continue }
                    seen.insert(nm)

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
        }
        return items
    }

    // MARK: - pomiar

    /// `du -sk`. Świadomie shell-out: na APFS nie ma taniego API na rozmiar katalogu,
    /// a własna rekurencja po FileManagerze jest wolniejsza niż du.
    private static func size(of path: String) -> UInt64? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        task.arguments = ["-sk", path]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8),
              let kb = UInt64(text.split(separator: "\t").first?
                  .trimmingCharacters(in: .whitespaces) ?? "") else { return nil }
        return kb * 1024
    }

    private static func shorten(_ path: String, _ home: String) -> String {
        let p = path.replacingOccurrences(of: home, with: "~")
        return p.count > 60 ? "…" + String(p.suffix(58)) : p
    }
}
