import AppKit

/// Settings › General › App Language (#331). macOS picks an app's language once, at launch, from the
/// app's own `AppleLanguages` preference and then the system's. System Settings › Language & Region ›
/// Applications writes that same per-app key, so the picker and System Settings stay in step; a
/// change shows after Stow restarts.
nonisolated enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    static let key = "AppleLanguages"

    var id: String { rawValue }

    /// Each language in its own script, as language menus show them. "System" is localized.
    var endonym: String? {
        switch self {
        case .system: nil
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }

    /// What `store`'s own domain asks for: nothing (follow the system) or the Stow localization the
    /// saved list resolves to, whether the picker or System Settings saved it.
    static func saved(in store: UserDefaults = .standard, domain: String = bundleIdentifier,
                      localizations: [String] = Bundle.main.localizations) -> AppLanguage {
        guard let languages = store.persistentDomain(forName: domain)?[key] as? [String], !languages.isEmpty
        else { return .system }
        return resolve(languages, localizations: localizations)
    }

    /// Saves `choice` for the next launch. System removes the app's own list.
    static func save(_ choice: AppLanguage, in store: UserDefaults = .standard) {
        switch choice {
        case .system: store.removeObject(forKey: key)
        case .english, .simplifiedChinese: store.set([choice.rawValue], forKey: key)
        }
    }

    /// The localization Stow would show for `choice`: its own, or the system's preference.
    static func effective(_ choice: AppLanguage, systemLanguages: [String] = systemLanguages,
                          localizations: [String] = Bundle.main.localizations) -> AppLanguage {
        choice == .system ? resolve(systemLanguages, localizations: localizations) : choice
    }

    /// The localization this running Stow loaded.
    static var running: AppLanguage { resolve(Bundle.main.preferredLocalizations, localizations: Bundle.main.localizations) }

    /// The system list without Stow's own override (`Locale.preferredLanguages` includes it).
    static var systemLanguages: [String] {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[key] as? [String]
            ?? Locale.preferredLanguages
    }

    static func resolve(_ languages: [String], localizations: [String]) -> AppLanguage {
        let available = localizations.filter { $0 != "Base" }
        let match = Bundle.preferredLocalizations(from: available, forPreferences: languages).first ?? "en"
        return match.hasPrefix("zh") ? .simplifiedChinese : .english
    }

    private static var bundleIdentifier: String { Bundle.main.bundleIdentifier ?? "app.stow.Stow" }
}

/// Restart Stow to show another language. Quitting goes through the usual checks: a running task
/// refuses the quit, and unsaved edits ask first. A refused quit cancels the restart rather than
/// queueing it, so the user restarts again once the task is done.
@MainActor
enum AppRestart {
    private(set) static var isRequested = false

    static func request() {
        isRequested = true
        NSApp.terminate(nil)
    }

    /// The quit was refused or abandoned: a later ⌘Q must not reopen Stow.
    static func cancel() { isRequested = false }

    /// Left for the new instance, which reopens Settings › General in the new language: a relaunch
    /// without a window would look as if Stow had simply quit. Launch Services doesn't pass launch
    /// arguments from a sandboxed app, so it's a time stamp in Stow's own defaults, read once.
    static let relaunchKey = "general.languageRestart"

    /// True once, for a launch within a minute of a language restart.
    static func wasRelaunched(in store: UserDefaults = .standard, now: Date = .now) -> Bool {
        guard let requested = store.object(forKey: relaunchKey) as? Date else { return false }
        store.removeObject(forKey: relaunchKey)
        return now.timeIntervalSince(requested) < 60
    }

    /// From `applicationWillTerminate`. Launch Services starts the new instance while this one exits;
    /// wait briefly so the request leaves before the process does.
    static func relaunchIfRequested(in store: UserDefaults = .standard) {
        guard isRequested else { return }
        isRequested = false
        store.set(Date.now, forKey: relaunchKey)
        store.synchronize()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        let sent = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            sent.signal()
        }
        _ = sent.wait(timeout: .now() + 3)
    }
}
