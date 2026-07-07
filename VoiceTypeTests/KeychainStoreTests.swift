import XCTest

@testable import VoiceType

final class KeychainStoreTests: XCTestCase {
    private let account = "test-keychain-store"

    override func tearDown() {
        KeychainStore.set("", account: account)  // 空值即删除
        UserDefaults.standard.removeObject(forKey: "polishAPIKey")
        KeychainStore.set("", account: "test-polish-api-key")
        super.tearDown()
    }

    func testGetMissingReturnsNil() {
        XCTAssertNil(KeychainStore.get(account))
    }

    func testSetGetRoundTrip() {
        KeychainStore.set("sk-secret-1", account: account)
        XCTAssertEqual(KeychainStore.get(account), "sk-secret-1")
    }

    func testOverwrite() {
        KeychainStore.set("v1", account: account)
        KeychainStore.set("v2", account: account)
        XCTAssertEqual(KeychainStore.get(account), "v2")
    }

    func testEmptyValueDeletes() {
        KeychainStore.set("v1", account: account)
        KeychainStore.set("", account: account)
        XCTAssertNil(KeychainStore.get(account))
    }

    func testMigrationMovesLegacyPolishKey() {
        UserDefaults.standard.set("legacy-key", forKey: "polishAPIKey")
        SettingsStore.migrateSecretsToKeychainIfNeeded(polishAccount: "test-polish-api-key")
        XCTAssertEqual(KeychainStore.get("test-polish-api-key"), "legacy-key")
        XCTAssertNil(UserDefaults.standard.string(forKey: "polishAPIKey"))
    }
}
