import SwiftUI

enum Tab: String, CaseIterable {
    case overview = "Przegląd"
    case processes = "Procesy"
    case disk = "Dysk"

    var symbol: String {
        switch self {
        case .overview:  return "chart.bar.fill"
        case .processes: return "cpu"
        case .disk:      return "internaldrive"
        }
    }
}

struct RootView: View {
    @ObservedObject var engine: Engine
    @State private var tab: Tab = .overview

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { t in
                    Label(t.rawValue, systemImage: t.symbol).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            Group {
                switch tab {
                case .overview:  OverviewView(engine: engine)
                case .processes: ProcessesView(engine: engine)
                case .disk:      DiskView(engine: engine)
                }
            }
            .frame(height: 430)

            Divider()
            footer
        }
        .frame(width: 460)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "figure.walk.motion")
                .foregroundStyle(engine.criticalCount > 0 ? .red : .secondary)
            Text("Stray").font(.headline)
            if engine.criticalCount > 0 {
                Text("\(engine.criticalCount)")
                    .font(.caption2).bold().foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(.red))
            }
            Spacer()
            Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Zakończ Stray")
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            Text("\(engine.trackedCount) procesów pod obserwacją")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            // Narzędzie do łapania żarłoków musi publicznie pokazywać własny rachunek.
            Text(String(format: "Stray: %.2f%% CPU",
                        engine.selfCostMillis / (Sampler.interval * 1000) * 100))
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}
