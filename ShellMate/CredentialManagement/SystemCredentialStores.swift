import Foundation
#if canImport(Security)
  import Security
#endif

public final class UserDefaultsLegacyCredentialPreferences: LegacyCredentialPreferences,
  @unchecked Sendable
{
  public static let defaultLegacyKey = "apiKey"

  private let defaults: UserDefaults
  private let key: String

  public init(
    defaults: UserDefaults = .standard,
    key: String = UserDefaultsLegacyCredentialPreferences.defaultLegacyKey
  ) {
    self.defaults = defaults
    self.key = key
  }

  public func readLegacyCredential() throws -> LegacyCredentialValue {
    guard let value = defaults.object(forKey: key) else { return .missing }
    guard let value = value as? String else { return .malformed }
    return .string(value)
  }

  public func removeLegacyCredential() throws {
    defaults.removeObject(forKey: key)
  }
}

#if canImport(Security)
  public enum KeychainCredentialStoreOperation: String, Equatable, Sendable {
    case read
    case write
    case delete
  }

  public enum KeychainCredentialStoreError: Error, Equatable, Sendable {
    case status(operation: KeychainCredentialStoreOperation, code: OSStatus)
    case malformedCredential
  }

  extension KeychainCredentialStoreError: LocalizedError {
    public var errorDescription: String? {
      switch self {
      case .status(let operation, let code):
        return "Keychain \(operation.rawValue) failed with status \(code)."
      case .malformedCredential:
        return "Keychain returned malformed credential data."
      }
    }
  }

  /// Generic-password storage scoped to one service/account pair.
  public final class MacOSKeychainCredentialStore: CredentialStore, @unchecked Sendable {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
      self.service = service
      self.account = account
    }

    public func readCredential() throws -> String? {
      var query = baseQuery
      query[kSecReturnData as String] = true
      query[kSecMatchLimit as String] = kSecMatchLimitOne

      var result: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      if status == errSecItemNotFound { return nil }
      guard status == errSecSuccess else {
        throw KeychainCredentialStoreError.status(operation: .read, code: status)
      }
      guard let data = result as? Data, let credential = String(data: data, encoding: .utf8) else {
        throw KeychainCredentialStoreError.malformedCredential
      }
      return credential
    }

    public func writeCredential(_ credential: String) throws {
      let data = Data(credential.utf8)
      let update = [kSecValueData as String: data]
      var status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)

      if status == errSecItemNotFound {
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        status = SecItemAdd(item as CFDictionary, nil)

        // Another process or a duplicate legacy item may have won the add race. Updating makes the
        // operation idempotent and avoids treating a duplicate item as a crash-worthy condition.
        if status == errSecDuplicateItem {
          status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        }
      }

      guard status == errSecSuccess else {
        throw KeychainCredentialStoreError.status(operation: .write, code: status)
      }
    }

    public func deleteCredential() throws {
      let status = SecItemDelete(baseQuery as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw KeychainCredentialStoreError.status(operation: .delete, code: status)
      }
    }

    private var baseQuery: [String: Any] {
      [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
      ]
    }
  }
#endif
