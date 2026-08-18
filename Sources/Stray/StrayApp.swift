import SwiftUI

/// Startuje silnik w momencie uruchomienia procesu.
///
/// Bez tego `engine.start()` wisiało w `.onAppear` zawartości popovera — a przy
/// `MenuBarExtra(.window)` ta zawartość powstaje dopiero przy pierwszym kliknięciu
/// w ikonę. Aplikacja stała bezczynnie, dopóki ktoś jej nie otworzył: zero próbek,
/// zero powiadomień i — najgorsze — żadnej pamięci linii przodków, czyli jedynej
/// rzeczy, dla której to w ogóle musi być program rezydentny.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Engine.shared.start()
    }
}

@main
struct StrayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var engine = Engine.shared

    init() {
        // Tryb CLI: `Stray --scan` robi jeden przebieg i kończy, bez GUI.
        if CommandLine.arguments.contains("--scan") {
            CLI.scan()
            exit(0)
        }
        if CommandLine.arguments.contains("--footprint") {
            CLI.footprint()
            exit(0)
        }
        if CommandLine.arguments.contains("--clean") {
            CLI.cleanDryRun()
            exit(0)
        }
        if CommandLine.arguments.contains("--disk") {
            CLI.disk()
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            RootView(engine: engine)
        } label: {
            Image(systemName: iconName)
        }
        .menuBarExtraStyle(.window)
    }

    /// Ślad łapy: "stray" to bezpańskie zwierzę, więc nazwa i znak mówią to samo.
    /// Poprzednia sylwetka pieszego (`figure.walk`) czytała się w pasku jak aplikacja
    /// fitness — a w pasku menu, wśród samych figur geometrycznych, łapa jest
    /// natychmiast rozpoznawalna.
    private var iconName: String {
        engine.criticalCount > 0 || engine.warningCount > 0 ? "pawprint.fill" : "pawprint"
    }
}
