import SwiftUI

/// Ekran potwierdzenia. Świadomie gadatliwy: to jedyne miejsce w aplikacji,
/// gdzie kliknięcie robi coś, czego nie da się cofnąć restartem.
struct DeleteConfirmSheet: View {
    let items: [DiskItem]
    @ObservedObject var engine: Engine
    let dismiss: () -> Void

    private var total: UInt64 {
        items.reduce(0) { $0 + DiskActions.deletableBytes($1) }
    }
    private var touchesScratchpads: Bool {
        items.contains { DiskActions.isScratchpadRoot($0.path) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "trash").font(.title3).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("disk.confirm.title", items.count)).font(.headline)
                    Text(L("disk.confirm.total", byteString(total)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(items) { item in
                        HStack(spacing: 6) {
                            Circle().fill(item.confidence.color).frame(width: 5, height: 5)
                            Text(item.displayName)
                                .font(.caption).lineLimit(1).truncationMode(.head)
                            Spacer(minLength: 4)
                            Text(byteString(DiskActions.deletableBytes(item)))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxHeight: 150)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.3)))

            VStack(alignment: .leading, spacing: 4) {
                note("arrow.uturn.backward", L("disk.confirm.trash"))
                note("checkmark.shield", L("disk.confirm.revalidate"))
                if touchesScratchpads {
                    note("person.fill.checkmark", L("disk.confirm.scratchpad"))
                }
            }

            HStack {
                Button(L("disk.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                // Trwałe usunięcie schowane w menu, nie obok głównego przycisku —
                // nie chcemy, żeby dało się w nie trafić przez pomyłkę.
                Menu {
                    Button(L("disk.deleteperm"), role: .destructive) {
                        engine.deleteDisk(items, permanent: true); dismiss()
                    }
                } label: {
                    Text(L("disk.deleteperm")).font(.caption)
                }
                .menuStyle(.borderlessButton).fixedSize()

                Button {
                    engine.deleteDisk(items, permanent: false); dismiss()
                } label: {
                    Text(L("disk.trash"))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(width: 420)
    }

    private func note(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: symbol).font(.caption2).foregroundStyle(.secondary)
                .frame(width: 12)
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
