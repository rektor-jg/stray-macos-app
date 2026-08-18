import Foundation

enum DiskCategory: String, Codable, Sendable, CaseIterable {
    case agentData      // własne katalogi agentów
    case deadArtifact   // artefakt po projekcie, którego już nie ma
    case buildCache     // DerivedData, gradle, CoreSimulator
    case packageCache   // npm, pnpm, yarn
    case nodeModules

    var label: String {
        switch self {
        case .agentData:    return L("disk.category.agentData")
        case .deadArtifact: return L("disk.category.deadArtifact")
        case .buildCache:   return L("disk.category.buildCache")
        case .packageCache: return L("disk.category.packageCache")
        case .nodeModules:  return L("disk.category.nodeModules")
        }
    }
}

struct DiskItem: Codable, Sendable, Identifiable {
    let path: String
    let displayName: String
    let bytes: UInt64
    let category: DiskCategory
    let confidenceRaw: Int
    let safeToDelete: Bool
    let note: String
    let suggestedCommand: String?

    var id: String { path }
    var confidence: Confidence { Confidence(rawValue: confidenceRaw) ?? .inferred }
}

struct DiskReport: Codable, Sendable {
    var items: [DiskItem] = []
    var scannedAt: Date = Date()
    var durationSeconds: Double = 0

    func total(_ confidence: Confidence) -> UInt64 {
        items.filter { $0.confidence == confidence }.reduce(0) { $0 + $1.bytes }
    }
    var reclaimable: UInt64 { items.filter(\.safeToDelete).reduce(0) { $0 + $1.bytes } }
    var grandTotal: UInt64 { items.reduce(0) { $0 + $1.bytes } }

    func byCategory() -> [(DiskCategory, UInt64)] {
        DiskCategory.allCases
            .map { cat in (cat, items.filter { $0.category == cat }.reduce(0) { $0 + $1.bytes }) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
    }
}
