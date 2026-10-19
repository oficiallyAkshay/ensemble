import Foundation
import Testing
@testable import EnsembleCore

@Suite struct NoseDotDefaultTests {
    private func freshStore() -> UserDefaults {
        let name = "NoseDotDefaultTests-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        return store
    }

    private func dot(_ store: UserDefaults) -> Bool? {
        store.object(forKey: NoseDotDefault.valueKey) as? Bool
    }

    @Test func cleanFirstLaunchStoresOff() {
        let store = freshStore()
        NoseDotDefault.migrate(store)
        #expect(dot(store) == false)
        #expect(store.bool(forKey: NoseDotDefault.markerKey))
    }

    @Test func cleanStoreStaysOffAfterTourFlagsAndRelaunch() {
        let store = freshStore()
        NoseDotDefault.migrate(store)
        store.set(true, forKey: "tourSkipped")
        store.set(true, forKey: "tourCompleted")
        NoseDotDefault.migrate(store)
        #expect(dot(store) == false)
    }

    @Test func anyOneAppKeyMeansAnExistingInstall() {
        for key in NoseDotDefault.appKeys {
            let store = freshStore()
            store.set("x", forKey: key)
            NoseDotDefault.migrate(store)
            #expect(dot(store) == true, "key \(key)")
        }
        #expect(NoseDotDefault.appKeys.contains("lastClaudeVersion"))
        #expect(NoseDotDefault.appKeys.contains("tourCompleted"))
        #expect(!NoseDotDefault.appKeys.contains(NoseDotDefault.valueKey))
        #expect(!NoseDotDefault.appKeys.contains(NoseDotDefault.markerKey))
    }

    @Test func otherComponentsKeysAreNotAnInstall() {
        let store = freshStore()
        store.set(true, forKey: "SUEnableAutomaticChecks")
        NoseDotDefault.migrate(store)
        #expect(dot(store) == false)
    }

    @Test func storedValuesAreNeverOverwritten() {
        for stored in [true, false] {
            let store = freshStore()
            store.set(stored, forKey: NoseDotDefault.valueKey)
            store.set("1.0", forKey: "lastClaudeVersion")
            NoseDotDefault.migrate(store)
            #expect(dot(store) == stored)
        }
    }

    @Test func runsOnce() {
        let store = freshStore()
        NoseDotDefault.migrate(store)
        store.set("1.0", forKey: "lastClaudeVersion")
        NoseDotDefault.migrate(store)
        #expect(dot(store) == false)
    }
}
