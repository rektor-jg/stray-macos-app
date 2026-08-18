import Foundation

enum AgentSignatures {
    /// Dokładne nazwy binarek agentów. Dopasowanie jest ścisłe, nie po przedrostku.
    ///
    /// Przedrostek był tu błędem: `"cursoruiviewservice".hasPrefix("cursor")` daje trafienie,
    /// a `CursorUIViewService` to usługa systemowa Apple od kursora tekstowego
    /// (`/System/Library/PrivateFrameworks/TextInputUIMacHelper.framework`), nie edytor Cursor.
    /// Apple'owska usługa była przez to liczona jako proces AI.
    static let exactNames: Set<String> = [
        "claude", "claude.exe", "codex", "cursor", "aider", "copilot",
        "gemini", "opencode", "goose", "crush",
    ]

    /// Procesy pomocnicze aplikacji desktopowych. Tu przedrostek jest bezpieczny,
    /// bo obejmuje dwa słowa — żadna usługa systemowa nie nazywa się „claude helper".
    static let helperPrefixes = ["claude helper", "cursor helper", "codex helper"]

    static func isAgent(_ name: String) -> Bool {
        let n = name.lowercased()
        return exactNames.contains(n) || helperPrefixes.contains { n.hasPrefix($0) }
    }

    /// Wersja ze ścieżką — mocniejsza, bo odrzuca cokolwiek, co przyszło z systemu.
    /// Apple nie dostarcza agentów AI, więc żaden proces spod `/System/` nim nie jest.
    static func isAgent(name: String, command: String) -> Bool {
        guard !command.hasPrefix("/System/"), !command.contains("/System/Library/") else {
            return false
        }
        return isAgent(name)
    }
}
