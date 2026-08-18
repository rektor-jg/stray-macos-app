import Darwin
import Foundation

enum ProcessActions {

    /// Ubija CAŁE poddrzewo, od liści w górę.
    ///
    /// Ubicie samego korzenia (`npm`) zostawiłoby działającego wnuka (`next-server`)
    /// z jego 531 MB — i osierociłoby go jeszcze bardziej niż był.
    /// Drzewo liczymy na świeżo, bo od ostatniej próbki mogło się zmienić.
    @discardableResult
    static func terminateTree(pid: Int32, expectedStart: Date? = nil,
                              graceSeconds: TimeInterval = 5.0) -> Int {
        // Strażnik recyklingu PID-u: między skanem a kliknięciem proces mógł umrzeć,
        // a jądro mogło nadać ten sam numer czemuś zupełnie innemu.
        // Czas startu jest niepodrabialny w praktyce i kosztuje jeden syscall.
        if let expectedStart, !startMatches(pid: pid, expected: expectedStart) { return 0 }
        let targets = subtree(of: pid)
        var killed = 0
        // od liści do korzenia — inaczej rodzic zdąży osierocić dzieci
        for target in targets.reversed() where terminate(pid: target, graceSeconds: graceSeconds) {
            killed += 1
        }
        return killed
    }

    /// Czy proces o tym PID-zie to nadal ten sam proces, który widzieliśmy przy skanie.
    static func startMatches(pid: Int32, expected: Date, tolerance: TimeInterval = 1.5) -> Bool {
        guard let (_, _, _, _, started) = ProcScanner.sample(pid, at: Date()) else { return false }
        return abs(started.timeIntervalSince(expected)) < tolerance
    }

    /// Korzeń + wszyscy potomkowie, w kolejności od korzenia w dół.
    static func subtree(of root: Int32) -> [Int32] {
        var children: [Int32: [Int32]] = [:]
        for pid in ProcScanner.listPIDs() {
            guard let (metrics, _, _, _, _) = ProcScanner.sample(pid, at: Date()) else { continue }
            children[metrics.ppid, default: []].append(pid)
        }
        var result: [Int32] = [root]
        var frontier = children[root] ?? []
        var depth = 0
        while !frontier.isEmpty && depth < 12 {
            result.append(contentsOf: frontier)
            frontier = frontier.flatMap { children[$0] ?? [] }
            depth += 1
        }
        return result
    }

    /// Grzecznie, potem stanowczo. Działa bez roota na procesach własnego UID.
    @discardableResult
    static func terminate(pid: Int32, graceSeconds: TimeInterval = 5.0) -> Bool {
        guard kill(pid, SIGTERM) == 0 else { return false }
        let deadline = Date().addingTimeInterval(graceSeconds)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return true }   // już nie żyje
            usleep(200_000)
        }
        return kill(pid, SIGKILL) == 0
    }

    static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    /// Diagnoza on-demand: /usr/bin/sample nie wymaga uprawnień dla własnego UID.
    /// To jest wyróżnik produktu — przeskok z "coś zżera CPU" na "utknęło w silniku regexa".
    static func sampleStack(pid: Int32, seconds: Int = 2) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        task.arguments = ["\(pid)", "\(seconds)", "-mayDie"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// Tłumaczy ramki stosu na przyczynę po ludzku.
    /// Lista rośnie z doświadczeniem — pierwszy wpis pochodzi z incydentu,
    /// który dał początek temu projektowi.
    static func explain(stack: String) -> String? {
        let signatures: [(needle: String, meaning: String)] = [
            ("sre_match",        "silnik regex — prawdopodobny catastrophic backtracking"),
            ("_sre",             "silnik regex — prawdopodobny catastrophic backtracking"),
            ("RegExp",           "silnik regex JS — prawdopodobny catastrophic backtracking"),
            ("malloc",           "intensywna alokacja pamięci"),
            ("gc_collect",       "pętla garbage collectora"),
            ("__psynch_cvwait",  "czeka na muteks — możliwy zakleszczony wątek"),
            ("read",             "czeka na I/O"),
            ("json",             "parsowanie JSON — możliwe ogromne wejście"),
        ]
        for s in signatures where stack.contains(s.needle) { return s.meaning }
        return nil
    }

    /// Raport do wklejenia agentowi, który ten kod napisał.
    static func report(for finding: Finding, stack: String? = nil) -> String {
        var lines = [
            "## Stray — \(finding.detector.label) (\(finding.detector.rawValue))",
            "",
            "**\(finding.title)** · PID \(finding.pid)",
            finding.summary,
            "",
        ]
        lines += finding.detail.map { "- \($0)" }
        if let a = finding.attribution { lines += ["", "Pochodzenie: \(a)"] }
        lines += ["", "```", SecretMasker.mask(finding.command), "```"]

        if let stack {
            if let why = explain(stack: stack) {
                lines += ["", "**Diagnoza:** \(why)"]
            }
            let head = stack.split(separator: "\n").prefix(40).joined(separator: "\n")
            lines += ["", "<details><summary>stos (sample)</summary>", "", "```",
                      SecretMasker.mask(head), "```", "</details>"]
        }
        return lines.joined(separator: "\n")
    }
}

/// Linie poleceń procesów regularnie zawierają klucze API i tokeny.
/// Stray je czyta, więc nie wolno mu ich oddać do schowka w czystej postaci.
enum SecretMasker {
    /// Wzorce celowo LINIOWE — bez zagnieżdżonych kwantyfikatorów.
    /// Byłoby żenujące, gdyby narzędzie do wykrywania catastrophic backtrackingu
    /// samo się na nim zawiesiło.
    /// Prefiksy tokenów o rozpoznawalnym kształcie.
    private static let prefixes = [
        "sk-", "sk_live_", "sk_test_", "ghp_", "gho_", "ghu_", "ghs_", "ghr_",
        "github_pat_", "glpat-", "AKIA", "ASIA", "xoxb-", "xoxp-", "xoxa-", "xapp-",
        "AIza", "ya29.", "npm_", "hf_", "dop_v1_", "shpat_", "SG.", "rk_live_",
    ]

    /// Nazwy parametrów, po których idzie sekret bez własnego prefiksu.
    /// Obie formy — z `=` i ze spacją — bo obie są w codziennym użyciu.
    private static let keywords = [
        "Bearer ", "--token=", "--token ", "--api-key=", "--api-key ", "--apikey=",
        "--secret=", "--secret ", "--password=", "--password ", "--auth=",
        "--hf-token ", "--access-token=", "--access-token ",
        "TOKEN=", "SECRET=", "API_KEY=", "APIKEY=", "PASSWORD=", "ACCESS_TOKEN=",
    ]

    static func mask(_ text: String) -> String {
        var out = text
        for prefix in prefixes { out = maskAfter(prefix, in: out) }
        for keyword in keywords { out = maskAfter(keyword, in: out) }
        return out
    }

    /// Skanowanie znak po znaku — złożoność liniowa, zero backtrackingu.
    private static func maskAfter(_ prefix: String, in text: String) -> String {
        guard text.contains(prefix) else { return text }
        var result = ""
        var rest = Substring(text)
        while let range = rest.range(of: prefix) {
            result += rest[rest.startIndex..<range.upperBound]
            var idx = range.upperBound
            var consumed = 0
            while idx < rest.endIndex, isTokenChar(rest[idx]) { idx = rest.index(after: idx); consumed += 1 }
            if consumed >= 8 { result += "…[zamaskowane]" } else { result += rest[range.upperBound..<idx] }
            rest = rest[idx...]
        }
        return result + rest
    }

    private static func isTokenChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "-" || c == "."
    }
}
