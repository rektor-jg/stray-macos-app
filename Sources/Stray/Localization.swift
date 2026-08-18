import Foundation

/// Język interfejsu.
///
/// Domyślnie `.system` — macOS sam wybiera lokalizację z listy preferowanych języków
/// użytkownika, więc żaden przełącznik nie jest potrzebny. Nadpisanie istnieje tylko
/// na wypadek, gdy ktoś chce wymusić język inny niż systemowy.
enum Lang: String, CaseIterable {
    case system, en, pl

    var label: String {
        switch self {
        case .system: return L("lang.system")
        case .en:     return "English"
        case .pl:     return "Polski"
        }
    }
}

final class Localizer: ObservableObject {
    static let shared = Localizer()
    private static let key = "stray.language"

    @Published var current: Lang {
        didSet {
            UserDefaults.standard.set(current.rawValue, forKey: Self.key)
            Localizer.cachedBundle = nil
        }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.key) ?? Lang.system.rawValue
        current = Lang(rawValue: raw) ?? .system
    }

    fileprivate static var cachedBundle: Bundle?

    static var bundle: Bundle {
        if let cached = cachedBundle { return cached }
        let lang = Lang(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
        let resolved: Bundle
        if lang != .system,
           let path = Bundle.module.path(forResource: lang.rawValue, ofType: "lproj"),
           let override = Bundle(path: path) {
            resolved = override
        } else {
            resolved = .module
        }
        cachedBundle = resolved
        return resolved
    }
}

/// Skrót na tłumaczenie. Krótki celowo — pojawia się w kodzie kilkaset razy.
func L(_ key: String) -> String {
    NSLocalizedString(key, bundle: Localizer.bundle, comment: "")
}

/// Wersja z argumentami formatu.
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, bundle: Localizer.bundle, comment: ""), arguments: args)
}
