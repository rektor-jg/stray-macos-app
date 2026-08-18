import SwiftUI

enum Tab: String, CaseIterable {
    case overview, processes, disk

    var title: String {
        switch self {
        case .overview:  return L("tab.overview")
        case .processes: return L("tab.processes")
        case .disk:      return L("tab.disk")
        }
    }

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
    @ObservedObject private var localizer = Localizer.shared
    @State private var tab: Tab = .overview

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { t in
                    Label(t.title, systemImage: t.symbol).tag(t)
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
        .id(localizer.current)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: engine.criticalCount > 0 ? "pawprint.fill" : "pawprint")
                .foregroundStyle(engine.criticalCount > 0 ? .red : .secondary)
            Text("Stray").font(.headline)
            if engine.criticalCount > 0 {
                Text("\(engine.criticalCount)")
                    .font(.caption2).bold().foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(.red))
            }
            Spacer()
            // Jedyne miejsce, gdzie jest miejsce na ustawienia — i jedyne, którego potrzebują.
            Menu {
                Picker(L("app.language"), selection: $localizer.current) {
                    ForEach(Lang.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Divider()
                Button(L("app.quit")) { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).frame(width: 28).foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            Text(L("app.tracked", engine.trackedCount))
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            // Narzędzie do łapania żarłoków musi publicznie pokazywać własny rachunek.
            Text(L("app.selfcost", engine.selfCostMillis / (Sampler.interval * 1000) * 100))
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}
