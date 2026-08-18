import SwiftUI

struct DiskView: View {
    @ObservedObject var engine: Engine
    @State private var showOnlyReclaimable = false

    var body: some View {
        VStack(spacing: 0) {
            if let stage = engine.diskStage {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Skanuję: \(stage)…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let report = engine.diskReport {
                content(report)
            } else {
                VStack(spacing: 8) {
                    Text("Skan dyskowy nie był jeszcze uruchomiony")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Skanuj teraz") { engine.scanDisk() }.controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func content(_ report: DiskReport) -> some View {
        VStack(spacing: 0) {
            // podsumowanie kategorii
            VStack(alignment: .leading, spacing: 6) {
                ShareBar(segments: report.byCategory().map {
                    (Double($0.1), categoryColor($0.0))
                }, height: 10)
                HStack(spacing: 8) {
                    ForEach(report.byCategory(), id: \.0.rawValue) { cat, bytes in
                        HStack(spacing: 3) {
                            Circle().fill(categoryColor(cat)).frame(width: 6, height: 6)
                            Text("\(cat.label) \(byteString(bytes))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Toggle("Tylko bezpieczne do usunięcia", isOn: $showOnlyReclaimable)
                        .toggleStyle(.checkbox).font(.caption2)
                    Spacer()
                    Button { engine.scanDisk() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Skan trwa ok. \(Int(report.durationSeconds)) s")
                }
            }
            .padding(10)
            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(report.items.filter { !showOnlyReclaimable || $0.safeToDelete }) { item in
                        DiskItemRow(item: item)
                        Divider()
                    }
                }
            }

            Divider()
            HStack {
                Text("Razem \(byteString(report.grandTotal))").font(.caption2)
                Spacer()
                Text("bezpiecznie odzyskiwalne \(byteString(report.reclaimable))")
                    .font(.caption2).foregroundStyle(.green)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
    }

    private func categoryColor(_ c: DiskCategory) -> Color {
        switch c {
        case .agentData:    return .green
        case .deadArtifact: return .red
        case .buildCache:   return .orange
        case .packageCache: return .blue
        case .nodeModules:  return .purple
        }
    }
}

struct DiskItemRow: View {
    let item: DiskItem
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: item.confidence.symbol)
                    .font(.caption2).foregroundStyle(item.confidence.color)
                Text(item.displayName).font(.callout).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 4)
                Text(byteString(item.bytes))
                    .font(.caption).bold()
                    .foregroundStyle(Heat.forDisk(bytes: item.bytes).color)
            }
            Text(item.note).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            if let cmd = item.suggestedCommand {
                HStack(spacing: 6) {
                    Text(cmd)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    Button(copied ? "✓" : "Kopiuj") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(cmd, forType: .string)
                        copied = true
                    }
                    .buttonStyle(.borderless).controlSize(.mini).font(.caption2)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }
}
