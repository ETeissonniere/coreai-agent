import Foundation

enum AppPreferences {
    static let allowWebSearchByDefaultKey = "allowWebSearchByDefault"

    static var allowsWebSearchByDefault: Bool {
        UserDefaults.standard.bool(forKey: allowWebSearchByDefaultKey)
    }
}
