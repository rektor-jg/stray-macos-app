import Foundation

enum Titles {
    /// Sesja-źródło znaleziska. Środowisko daje PID sesji; sprawdzamy, czy żyje,
    /// i dociągamy jej terminal — bo „ttys000" jest dla człowieka adresem,
    /// a „PID 2061" tylko liczbą.
    static func source(for meta: ProcMeta) -> SessionSource? {
        guard let env = meta.agentEnv else {
            // zapas: linia przodków bez środowiska — wiemy „kto", nie wiemy „która"
            guard let vendor = meta.agentSession else { return nil }
            return SessionSource(vendor: vendor, sessionID: nil, pid: nil, alive: false, tty: nil)
        }
        let pid = env.agentPID
        let alive = pid.map(ProcessActions.isAlive) ?? false
        let tty = (alive ? pid : nil).flatMap(ProcScanner.controllingTTY)
        return SessionSource(vendor: env.vendor, sessionID: env.sessionID,
                             pid: pid, alive: alive, tty: tty)
    }

    /// Zwięzła nazwa do listy: "next dev :3111" zamiast 200 znaków argv.
    static func short(for meta: ProcMeta) -> String {
        let cmd = meta.command
        for marker in ["next dev", "expo start", "vite", "metro", "webpack", "nodemon",
                       "jest", "pytest", "tsc", "rollup", "storybook"] {
            if cmd.contains(marker) {
                if let port = extractPort(cmd) { return "\(marker) :\(port)" }
                return marker
            }
        }
        return meta.name
    }

    /// Wyciąga numer portu bez regexa — świadomie, bo ten projekt powstał
    /// przez catastrophic backtracking w cudzym regexie.
    private static func extractPort(_ cmd: String) -> String? {
        let tokens = cmd.split(separator: " ").map(String.init)
        for (i, t) in tokens.enumerated() {
            if (t == "-p" || t == "--port" || t == "-port"), i + 1 < tokens.count,
               Int(tokens[i + 1]) != nil {
                return tokens[i + 1]
            }
            if t.hasPrefix("--port="), let v = t.split(separator: "=").last, Int(v) != nil {
                return String(v)
            }
        }
        return nil
    }

    static func attribution(for meta: ProcMeta) -> String? {
        // Środowisko: pomiar. Działa nawet dla sierot, bo dziedziczy się przez exec
        // i przeżywa śmierć rodzica.
        if let env = meta.agentEnv {
            let who = meta.sessionLabel ?? env.vendor
            if let pid = env.agentPID, ProcessActions.isAlive(pid) {
                return L("attribution.env.live", who, pid)
            }
            if let pid = env.agentPID {
                return L("attribution.env.dead", who, pid)
            }
            return L("attribution.env", who)
        }
        if let agent = meta.agentSession {
            return L("attribution.agent", agent, meta.originalPPID)
        }
        guard !meta.originalAncestry.isEmpty else {
            // Stray wystartował już po osieroceniu — linii przodków nie ma jak odtworzyć.
            // Od następnego takiego procesu będzie, bo zobaczymy go za życia rodzica.
            return meta.originalPPID <= 1 ? L("attribution.unknown") : nil
        }
        return L("attribution.parent", meta.originalAncestry.prefix(3).joined(separator: " ← "))
    }
}
