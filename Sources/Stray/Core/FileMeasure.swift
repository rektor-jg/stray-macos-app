import Foundation

/// Wspólne czytanie z dysku dla skanera i dla kasowania.
///
/// Wcześniej ten sam kod żył w dwóch plikach pod dwiema nazwami (`size(of:)`
/// i `directorySize`), co znaczy, że poprawka w jednym miejscu omijała drugie —
/// a to akurat kod, który decyduje, ile obiecujemy odzyskać i co wolno skasować.
enum FileMeasure {

    /// `du -sk`. Świadomy shell-out: na APFS nie ma taniego API na rozmiar katalogu,
    /// a własna rekurencja po FileManagerze jest wolniejsza niż du.
    static func size(_ path: String) -> UInt64? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        task.arguments = ["-sk", path]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8),
              let kb = UInt64(text.split(separator: "\t").first?
                  .trimmingCharacters(in: .whitespaces) ?? "") else { return nil }
        return kb * 1024
    }

    /// Kilka pomiarów naraz. `du` czeka głównie na dysk, nie na procesor,
    /// więc równoległość skraca pełny skan kilkukrotnie.
    static func sizes(_ paths: [String], maxConcurrent: Int = 6) -> [String: UInt64] {
        var result: [String: UInt64] = [:]
        let lock = NSLock()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = maxConcurrent
        for path in paths {
            queue.addOperation {
                guard let bytes = size(path) else { return }
                lock.lock(); result[path] = bytes; lock.unlock()
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        return result
    }

    /// `WorkspacePath` z `info.plist` katalogu DerivedData — ścieżka projektu,
    /// dla którego ten build powstał.
    static func workspacePath(plist: String) -> String? {
        guard let data = FileManager.default.contents(atPath: plist),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = obj as? [String: Any] else { return nil }
        return dict["WorkspacePath"] as? String
    }

    /// Katalog scratchpadów bieżącego użytkownika.
    ///
    /// Numer w nazwie to UID, nie stała — zaszycie `501` znaczyło, że na każdym
    /// innym koncie skan po cichu nie znajdował niczego.
    static var scratchpadRoot: String { "/private/tmp/claude-\(getuid())" }
    static var scratchpadPrefix: String { "/private/tmp/claude-" }
}
