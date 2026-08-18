import Foundation

/// Klasyfikacja procesów — odpowiada na pytanie "czym to w ogóle jest".
///
/// Najważniejszy plik w projekcie mimo że wygląda najbanalniej: to on decyduje,
/// czy detektor odezwie się na legalny build. Produkt, który krzyczy przy każdej
/// kompilacji, zostaje wyłączony w tydzień.
///
/// (Dawniej `Whitelist` — nazwa opisywała tylko połowę tego, co ten typ robił,
/// bo trzymał też listę ignorowanych przez użytkownika. Ta druga rola żyje
/// teraz w `IgnoreList`.)
enum ProcessRules {

    /// Narzędzia, którym wolno palić 100% CPU godzinami. Build to nie jest awaria.
    private static let buildTools = [
        "xcodebuild", "swift-frontend", "swiftc", "clang", "ld", "gradle", "kotlinc",
        "cargo", "rustc", "go build", "webpack", "esbuild", "rollup", "turbo",
        "cmake", "ninja", "make", "javac", "dart", "flutter", "pod install",
    ]

    /// Procesy CLI, których osierocenie jest podejrzane.
    private static let devTools = [
        "npm", "npx", "pnpm", "yarn", "bun", "node", "deno",
        "next", "vite", "metro", "expo", "nodemon", "webpack-dev-server",
        "python", "python3", "flask", "uvicorn", "gunicorn", "django",
        "rails", "puma", "php", "artisan", "jekyll", "hugo",
        "watchman", "tsc", "jest", "vitest", "storybook",
    ]

    static func isLongRunningBuild(_ command: String) -> Bool {
        let c = command.lowercased()
        return buildTools.contains { c.contains($0) }
    }

    static func isDevTool(_ command: String) -> Bool {
        let c = command.lowercased()
        return devTools.contains { token in
            // dopasowanie po całych słowach, żeby "node" nie łapało "/Applications/Nodegraph.app"
            c.split(whereSeparator: { " /=".contains($0) }).contains(Substring(token))
        }
    }

    /// KAŻDA aplikacja GUI ma PPID 1, bo uruchamia ją launchd.
    /// Bez tego filtra detektor sierot zgłosiłby cały Dock użytkownika.
    static func isGUIApp(_ command: String) -> Bool {
        command.contains(".app/Contents/")
            || command.hasPrefix("/System/")
            || command.hasPrefix("/Applications/")
            || command.contains("/Library/PrivateFrameworks/")
            || command.contains("XPCServices")
    }
}
