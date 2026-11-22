import Foundation
import Testing
@testable import Stow

@Suite("App language")
struct AppLanguageTests {
    private let localizations = ["Base", "en", "zh-Hans"]

    private func withStore(_ body: (UserDefaults, String) throws -> Void) throws {
        let name = "AppLanguageTests.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: name))
        defer { store.removePersistentDomain(forName: name) }
        try body(store, name)
    }

    @Test func noListFollowsTheSystem() throws {
        try withStore { store, name in
            #expect(AppLanguage.saved(in: store, domain: name, localizations: localizations) == .system)
        }
    }

    @Test func pickerChoicesRoundTrip() throws {
        try withStore { store, name in
            AppLanguage.save(.simplifiedChinese, in: store)
            #expect(store.persistentDomain(forName: name)?[AppLanguage.key] as? [String] == ["zh-Hans"])
            #expect(AppLanguage.saved(in: store, domain: name, localizations: localizations) == .simplifiedChinese)

            AppLanguage.save(.english, in: store)
            #expect(AppLanguage.saved(in: store, domain: name, localizations: localizations) == .english)

            AppLanguage.save(.system, in: store)
            #expect(store.persistentDomain(forName: name)?[AppLanguage.key] == nil)
            #expect(AppLanguage.saved(in: store, domain: name, localizations: localizations) == .system)
        }
    }

    /// System Settings › Language & Region › Applications writes region-qualified lists.
    @Test func systemSettingsListsResolveToStowsLocalizations() throws {
        try withStore { store, name in
            store.set(["zh-Hans-US", "en-US"], forKey: AppLanguage.key)
            #expect(AppLanguage.saved(in: store, domain: name, localizations: localizations) == .simplifiedChinese)
            store.set(["en-GB"], forKey: AppLanguage.key)
            #expect(AppLanguage.saved(in: store, domain: name, localizations: localizations) == .english)
        }
    }

    @Test func systemChoiceShowsTheSystemsLanguage() {
        #expect(AppLanguage.effective(.system, systemLanguages: ["zh-Hans-CN"], localizations: localizations) == .simplifiedChinese)
        #expect(AppLanguage.effective(.system, systemLanguages: ["en-US", "zh-Hans-CN"], localizations: localizations) == .english)
        #expect(AppLanguage.effective(.english, systemLanguages: ["zh-Hans-CN"], localizations: localizations) == .english)
    }

    @Test func otherLanguagesFallBackToEnglish() {
        #expect(AppLanguage.resolve(["fr-FR"], localizations: localizations) == .english)
    }

    /// The restart marker reopens Settings once, and only for the launch the restart started.
    @Test func restartMarkerIsReadOnceAndExpires() throws {
        try withStore { store, _ in
            let now = Date.now
            #expect(!AppRestart.wasRelaunched(in: store, now: now))
            store.set(now.addingTimeInterval(-5), forKey: AppRestart.relaunchKey)
            #expect(AppRestart.wasRelaunched(in: store, now: now))
            #expect(!AppRestart.wasRelaunched(in: store, now: now))
            store.set(now.addingTimeInterval(-600), forKey: AppRestart.relaunchKey)
            #expect(!AppRestart.wasRelaunched(in: store, now: now))
            #expect(store.object(forKey: AppRestart.relaunchKey) == nil)
        }
    }

    @Test func choicesAreNamedInTheirOwnLanguage() {
        #expect(AppLanguage.english.endonym == "English")
        #expect(AppLanguage.simplifiedChinese.endonym == "简体中文")
        #expect(AppLanguage.system.endonym == nil)
    }
}
