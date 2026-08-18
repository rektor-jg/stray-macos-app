import SwiftUI

@main
struct StrayApp: App {
    @StateObject private var engine = Engine()

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
        if CommandLine.arguments.contains("--disk") {
            CLI.disk()
            exit(0)
        }
        Notifier.requestAuthorization()
    }

    var body: some Scene {
        MenuBarExtra {
            RootView(engine: engine)
                .onAppear { engine.start() }
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
