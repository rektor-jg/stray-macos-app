import Darwin
import Foundation

/// Cienka warstwa nad libproc. Wszystko tutaj działa na procesach własnego UID
/// bez sudo i bez uprawnień specjalnych — to świadoma decyzja projektowa:
/// zero promptów o hasło, zero helper-toola z SMJobBless.
/// Procesy agentów są zawsze user-owned, więc nic przez to nie tracimy.
enum ProcScanner {

    // Stałe z libproc.h — nie importują się do Swifta jako symbole.
    private static let PROC_ALL_PIDS: UInt32 = 1
    private static let PROC_PIDTASKALLINFO: Int32 = 2
    private static let RUSAGE_INFO_V4: Int32 = 4

    /// Zmierzone: 1048 procesów → ~2,3 ms na pełną próbkę (0,078% CPU przy oknie 3 s).
    static func listPIDs() -> [Int32] {
        let needed = proc_listpids(PROC_ALL_PIDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        // zapas na procesy powstałe między dwoma wywołaniami
        let capacity = Int(needed) / MemoryLayout<Int32>.size + 64
        var buffer = [Int32](repeating: 0, count: capacity)
        let got = proc_listpids(PROC_ALL_PIDS, 0, &buffer,
                                Int32(capacity * MemoryLayout<Int32>.size))
        guard got > 0 else { return [] }
        let count = Int(got) / MemoryLayout<Int32>.size
        return buffer[0..<count].filter { $0 > 0 }
    }

    private static func taskAllInfo(_ pid: Int32) -> proc_taskallinfo? {
        var info = proc_taskallinfo()
        let size = Int32(MemoryLayout<proc_taskallinfo>.size)
        let rc = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, $0, size)
        }
        return rc == size ? info : nil
    }

    private static func rusage(_ pid: Int32) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return rc == 0 ? info : nil
    }

    /// Dwa syscalle na proces. Zwraca nil dla procesów cudzych/roota — to normalne,
    /// ~27% procesów w systemie jest nieczytelnych i celowo je pomijamy.
    static func sample(_ pid: Int32, at now: Date) -> (ProcMetrics, uid_t, String, Int32, Date)? {
        guard let t = taskAllInfo(pid) else { return nil }
        let ru = rusage(pid)

        let name = withUnsafePointer(to: t.pbsd.pbi_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) }
        }
        let comm = withUnsafePointer(to: t.pbsd.pbi_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
        }

        let metrics = ProcMetrics(
            at: now,
            ppid: Int32(bitPattern: t.pbsd.pbi_ppid),
            threads: t.ptinfo.pti_threadnum,
            cpuNanos: UInt64(bitPattern: Int64(t.ptinfo.pti_total_user))
                    &+ UInt64(bitPattern: Int64(t.ptinfo.pti_total_system)),
            rss: UInt64(bitPattern: Int64(t.ptinfo.pti_resident_size)),
            diskRead: ru?.ri_diskio_bytesread ?? 0,
            diskWritten: ru?.ri_diskio_byteswritten ?? 0,
            wakeups: (ru?.ri_interrupt_wkups ?? 0) &+ (ru?.ri_pkg_idle_wkups ?? 0),
            contextSwitches: t.ptinfo.pti_csw
        )

        let started = Date(timeIntervalSince1970:
            Double(t.pbsd.pbi_start_tvsec) + Double(t.pbsd.pbi_start_tvusec) / 1_000_000)

        return (metrics, t.pbsd.pbi_uid, name.isEmpty ? comm : name,
                Int32(bitPattern: t.pbsd.pbi_ppid), started)
    }

    /// Ślad agenta odczytany ze ZMIENNYCH ŚRODOWISKOWYCH procesu.
    ///
    /// To jest pomiar, nie zgadywanie po nazwie binarki. Środowisko dziedziczy się przez
    /// `fork`/`exec`, więc potomek nosi te znaczniki przez całe życie — także wtedy, gdy
    /// rodzic dawno umarł i `ppid` wynosi 1. Dzięki temu da się przypisać sesję nawet
    /// procesom osieroconym, zanim Stray w ogóle wystartował.
    struct AgentEnv: Sendable {
        let vendor: String        // "claude", "codex", "cursor", "aider"
        let sessionID: String?    // stabilny identyfikator sesji
        let agentPID: Int32?      // PID sesji, która ten proces uruchomiła
        let entrypoint: String?   // "cli", "vscode", …
    }

    /// Klucze, których wartości wolno nam odczytać. Wszystko poza tą listą jest
    /// odrzucane, zanim opuści funkcję parsującą.
    ///
    /// To nie jest nadgorliwość: obok znaczników leży `CLAUDE_CODE_MESSAGING_TOKEN`,
    /// czyli żywy sekret. Czytanie cudzego środowiska oznacza przechodzenie obok
    /// haseł, kluczy API i tokenów — więc bierzemy wyłącznie to, co nazwane, i nigdy
    /// nie zatrzymujemy reszty ani na chwilę dłużej niż trwa pętla.
    private static let allowedEnvKeys: Set<String> = [
        "CLAUDECODE", "CLAUDE_CODE_SESSION_ID", "CLAUDE_PID", "CLAUDE_CODE_ENTRYPOINT",
        "CODEX_SESSION_ID", "CODEX_PID", "CODEX_ENTRYPOINT",
        "CURSOR_SESSION_ID", "CURSOR_TRACE_ID",
        "AIDER_SESSION_ID", "GEMINI_CLI_SESSION_ID",
    ]

    /// Dodatkowa blokada na wypadek, gdyby lista wyżej kiedyś urosła nieostrożnie.
    private static func isSecretKey(_ key: String) -> Bool {
        let k = key.uppercased()
        return k.contains("TOKEN") || k.contains("SECRET") || k.contains("PASSWORD")
            || k.contains("KEY") || k.contains("AUTH") || k.contains("CREDENTIAL")
    }

    /// Pełna linia poleceń przez KERN_PROCARGS2.
    /// Droższe niż proc_pidinfo, więc wołane WYŁĄCZNIE raz, przy pierwszym zobaczeniu procesu.
    ///
    /// Układ bufora: [int32 argc][exec_path\0][\0 padding][argv0\0][argv1\0]...[envp]
    /// Jeden `sysctl` daje i argumenty, i środowisko — więc czytamy oba naraz.
    /// Wołane wyłącznie raz na proces, przy pierwszym zobaczeniu.
    static func processInfo(_ pid: Int32) -> (command: String?, agent: AgentEnv?) {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return (nil, nil)
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return (nil, nil) }

        var argc: Int32 = 0
        memcpy(&argc, buffer, MemoryLayout<Int32>.size)
        guard argc > 0 else { return (nil, nil) }

        var i = MemoryLayout<Int32>.size
        while i < size && buffer[i] != 0 { i += 1 }   // przeskocz exec_path
        while i < size && buffer[i] == 0 { i += 1 }   // przeskocz wyrównanie

        var args: [String] = []
        var env: [String: String] = [:]
        var current = [CChar]()
        var seen: Int32 = 0

        while i < size {
            if buffer[i] == 0 {
                current.append(0)
                let piece = String(cString: current)
                current.removeAll(keepingCapacity: true)
                if seen < argc {
                    args.append(piece)
                    seen += 1
                } else if let eq = piece.firstIndex(of: "=") {
                    let key = String(piece[piece.startIndex..<eq])
                    // Wartość bierzemy TYLKO dla nazwanych kluczy. Reszta — w tym
                    // tokeny leżące tuż obok — jest porzucana natychmiast.
                    if allowedEnvKeys.contains(key), !isSecretKey(key) {
                        env[key] = String(piece[piece.index(after: eq)...])
                    }
                }
            } else {
                current.append(buffer[i])
            }
            i += 1
        }

        let command = args.joined(separator: " ")
        return (command.isEmpty ? nil : command, agentEnv(from: env))
    }

    private static func agentEnv(from env: [String: String]) -> AgentEnv? {
        if env["CLAUDECODE"] != nil || env["CLAUDE_CODE_SESSION_ID"] != nil {
            return AgentEnv(vendor: "claude",
                            sessionID: env["CLAUDE_CODE_SESSION_ID"],
                            agentPID: env["CLAUDE_PID"].flatMap(Int32.init),
                            entrypoint: env["CLAUDE_CODE_ENTRYPOINT"])
        }
        if env["CODEX_SESSION_ID"] != nil {
            return AgentEnv(vendor: "codex", sessionID: env["CODEX_SESSION_ID"],
                            agentPID: env["CODEX_PID"].flatMap(Int32.init),
                            entrypoint: env["CODEX_ENTRYPOINT"])
        }
        if let id = env["CURSOR_SESSION_ID"] ?? env["CURSOR_TRACE_ID"] {
            return AgentEnv(vendor: "cursor", sessionID: id, agentPID: nil, entrypoint: nil)
        }
        if let id = env["AIDER_SESSION_ID"] {
            return AgentEnv(vendor: "aider", sessionID: id, agentPID: nil, entrypoint: nil)
        }
        if let id = env["GEMINI_CLI_SESSION_ID"] {
            return AgentEnv(vendor: "gemini", sessionID: id, agentPID: nil, entrypoint: nil)
        }
        return nil
    }

    /// Zgodność wstecz dla miejsc, które potrzebują tylko linii poleceń.
    static func commandLine(_ pid: Int32) -> String? { processInfo(pid).command }

    /// Czy proces nasłuchuje na porcie TCP i ile ma nawiązanych połączeń.
    ///
    /// To rozstrzyga najtrudniejsze pytanie produktu: sierota "w użyciu" kontra sierota martwa.
    /// Metro z podpiętym symulatorem ma połączenia. Zapomniany `next dev` nie ma żadnych.
    static func socketState(_ pid: Int32) -> (listeningPorts: [Int], established: Int) {
        let PROC_PIDLISTFDS: Int32 = 1
        let PROC_PIDFDSOCKETINFO: Int32 = 3
        let PROX_FDTYPE_SOCKET: UInt32 = 2

        let bufSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufSize > 0 else { return ([], 0) }
        let count = Int(bufSize) / MemoryLayout<proc_fdinfo>.size
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count + 16)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds,
                               Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
        guard got > 0 else { return ([], 0) }

        var ports: [Int] = []
        var established = 0
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.size)
        where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var si = socket_fdinfo()
            let sz = Int32(MemoryLayout<socket_fdinfo>.size)
            let rc = withUnsafeMutablePointer(to: &si) {
                proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, $0, sz)
            }
            guard rc == sz, si.psi.soi_family == AF_INET || si.psi.soi_family == AF_INET6 else {
                continue
            }
            // TSI_S_LISTEN == 1, TSI_S_ESTABLISHED == 4 (netinet/tcp_fsm.h)
            let tcp = si.psi.soi_proto.pri_tcp
            switch tcp.tcpsi_state {
            case 1:
                let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded:
                    tcp.tcpsi_ini.insi_lport)))
                if port > 0 { ports.append(port) }
            case 4:
                established += 1
            default:
                break
            }
        }
        return (Array(Set(ports)).sorted(), established)
    }
}
