import SwiftUI

struct DiskView: View {
    @ObservedObject var engine: Engine
    @State private var showOnlyReclaimable = false
    @State private var pendingDeletion: [DiskItem]?

    var body: some View {
        VStack(spacing: 0) {
            if let stage = engine.diskStage {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("disk.scanning", stage)).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let report = engine.diskReport {
                content(report)
            } else {
                VStack(spacing: 8) {
                    Text(L("disk.notscanned"))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(L("disk.scannow")) { engine.scanDisk() }.controlSize(.small)
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
                    Toggle(L("disk.onlyreclaimable"), isOn: $showOnlyReclaimable)
                        .toggleStyle(.checkbox).font(.caption2)
                    Spacer()
                    Button { engine.scanDisk() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(L("disk.rescan", Int(report.durationSeconds)))
                }
            }
            .padding(10)
            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(report.items.filter { !showOnlyReclaimable || $0.safeToDelete }) { item in
                        DiskItemRow(item: item) { pendingDeletion = [item] }
                        Divider()
                    }
                }
            }

            Divider()
            VStack(spacing: 5) {
                HStack {
                    Text(L("disk.total", byteString(report.grandTotal))).font(.caption2)
                    Spacer()
                    if let result = engine.lastCleanup {
                        HStack(spacing: 4) {
                            Text(L("disk.freed", byteString(result.freed)))
                                .foregroundStyle(.green)
                            if result.skipped > 0 {
                                Text("· " + L("disk.skipped", result.skipped))
                                    .foregroundStyle(.orange)
                            }
                        }
                        .font(.caption2)
                    } else {
                        Text(L("disk.reclaimable", byteString(report.reclaimable)))
                            .font(.caption2).foregroundStyle(.green)
                    }
                }
                let safe = report.items.filter(\.safeToDelete)
                if !safe.isEmpty {
                    Button {
                        pendingDeletion = safe
                    } label: {
                        Label(L("disk.cleanall", byteString(deletableTotal(safe))),
                              systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.small)
                    .disabled(engine.isDeleting)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .sheet(item: Binding(
            get: { pendingDeletion.map { DeletionRequest(items: $0) } },
            set: { if $0 == nil { pendingDeletion = nil } }
        )) { request in
            DeleteConfirmSheet(items: request.items, engine: engine) { pendingDeletion = nil }
        }
    }

    /// Dla scratchpadów liczymy tylko te podkatalogi, które faktycznie znikną —
    /// obietnica w przycisku musi się zgadzać z tym, co się wydarzy.
    private func deletableTotal(_ items: [DiskItem]) -> UInt64 {
        items.reduce(0) { $0 + DiskActions.deletableBytes($1) }
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

struct DeletionRequest: Identifiable {
    let items: [DiskItem]
    var id: String { items.map(\.path).joined() }
}

struct DiskItemRow: View {
    let item: DiskItem
    var onDelete: (() -> Void)? = nil
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
                if item.safeToDelete, let onDelete {
                    Button(action: onDelete) { Image(systemName: "trash") }
                        .buttonStyle(.borderless).controlSize(.small)
                        .foregroundStyle(.secondary)
                        .help(L("disk.trash"))
                }
            }
            Text(item.note).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            if let cmd = item.suggestedCommand {
                HStack(spacing: 6) {
                    Text(cmd)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    Button(copied ? "✓" : L("disk.copy")) {
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
