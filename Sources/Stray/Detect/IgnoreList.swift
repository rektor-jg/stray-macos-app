import Foundation

/// Procesy, o które użytkownik prosił, żeby więcej nie pytać.
///
/// Trwałe między uruchomieniami, więc zapis idzie na dysk — i właśnie dlatego
/// odcisk jest maskowany PRZED zapisaniem. Bez tego `--token=ghp_…` z linii poleceń
/// zostawałby w pliku plist w jawnej postaci na zawsze.
enum IgnoreList {

    private static let defaultsKey = "stray.ignoredCommands"

    static func all() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
    }

    static func add(_ command: String) {
        var current = all()
        current.insert(fingerprint(command))
        UserDefaults.standard.set(Array(current), forKey: defaultsKey)
    }

    static func contains(_ command: String) -> Bool {
        all().contains(fingerprint(command))
    }

    /// Odcisk odporny na zmianę PID-a i ścieżek tymczasowych — inaczej "ignoruj ten proces"
    /// przestawałoby działać po każdym restarcie serwera.
    ///
    /// Maskowanie PRZED zapisem jest tu obowiązkowe, nie kosmetyczne: ta wartość ląduje
    /// w UserDefaults, czyli w pliku plist na dysku, który przeżywa aplikację i którego
    /// użytkownik nigdy nie ogląda. Bez tego `--token=ghp_…` z linii poleceń zostawałby
    /// tam w jawnej postaci na zawsze.
    ///
    /// Efekt uboczny jest pożądany: dwie komendy różniące się wyłącznie tokenem dają
    /// ten sam odcisk, więc "ignoruj" przeżywa rotację klucza.
    private static func fingerprint(_ command: String) -> String {
        SecretMasker.mask(command.split(separator: " ").prefix(4).joined(separator: " "))
    }
}
