import XCTest
import Foundation
#if canImport(Security)
import Security
#endif
@testable import FluxCore

/// D7: unsigned simulator test hosts get -34018 (errSecMissingEntitlement)
/// on permanent Keychain writes. Map exactly that failure to XCTSkip with
/// a message instead of failing; every other error still fails loudly.
/// macOS SPM runs (CI) and signed device runs execute these tests fully.
enum TestKeychain {
    static func loadOrCreateIdentity(tag: String) throws -> SecKey {
        do {
            return try IdentityKeys.loadOrCreate(tag: tag) as! SecKey
        } catch IdentityKeys.KeyError.generationFailed(let code)
            where code == Int(errSecMissingEntitlement)
        {
            throw XCTSkip(
                "unsigned test host: permanent Keychain needs keychain-access-groups (-34018); runs on signed devices"
            )
        }
    }
}
