import SwiftUI

struct PopoverView: View {
    @ObservedObject var engine: Engine

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if engine.findings.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(engine.findings) { finding in
                            FindingRow(finding: finding, engine: engine)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 420)
            }
            Divider()
            footer
        }
        .frame(width: 400)
    }

    private var header: some View {
        HStack {
            Image(systemName: "figure.walk.motion")
                .foregroundStyle(engine.criticalCount > 0 ? .red : .secondary)
            Text("Stray").font(.headline)
            Spacer()
            Button { NSApplication.shared.terminate(nil) } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Zakończ Stray")
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle").font(.title2).foregroundStyle(.green)
            Text("Czysto").font(.callout)
            Text("\(engine.trackedCount) procesów pod obserwacją")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var footer: some View {
        HStack {
            if engine.reclaimableBytes > 0 {
                Label(byteString(engine.reclaimableBytes) + " do odzyskania",
                      systemImage: "arrow.counterclockwise")
                    .font(.caption)
            }
            Spacer()
            // Narzędzie do łapania żarłoków musi publicznie pokazywać własny rachunek.
            Text(String(format: "Stray: %.3f%% CPU",
                        engine.selfCostMillis / (Sampler.interval * 1000) * 100))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help("\(String(format: "%.1f", engine.selfCostMillis)) ms na próbkę co \(Int(Sampler.interval)) s")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct FindingRow: View {
    let finding: Finding
    @ObservedObject var engine: Engine
    @State private var expanded = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8).padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(finding.title).font(.system(.body, design: .rounded)).bold()
                        Text("PID \(finding.pid)").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(finding.summary).font(.caption).foregroundStyle(.secondary)
                    if let attribution = finding.attribution {
                        Text("↳ " + attribution)
                            .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(finding.detail, id: \.self) { line in
                        Text("· " + line).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(finding.command)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                .padding(.leading, 16)
            }

            HStack(spacing: 8) {
                Button(copied ? "Skopiowano" : "Raport") {
                    engine.copyReport(finding)
                    copied = true
                }
                .disabled(copied)
                Button("Ubij") { engine.kill(finding) }
                Button(expanded ? "Mniej" : "Więcej") { expanded.toggle() }
                Spacer()
                Menu {
                    Button("Ignoruj ten proces") { engine.ignore(finding) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.leading, 16)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var color: Color {
        switch finding.severity {
        case .critical: return .red
        case .warning:  return .yellow
        case .info:     return .secondary
        }
    }
}

func byteString(_ bytes: UInt64) -> String {
    let mb = Double(bytes) / 1_048_576
    return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
}
