import Foundation
import Security

/// Stores the Webex bearer token outside Desklog's Codable configuration.
///
/// The token is deliberately kept in the user's local Keychain so it never
/// appears in UserDefaults, worklog JSON, summaries, or diagnostic messages.
struct WebexCredentialStore {
    private let service = "local.desklog.app.webex"
    private let account = "access-token"

    func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw WebexCredentialError.keychain(status)
        }
        guard let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WebexCredentialError.invalidStoredCredential
        }
        return token
    }

    func save(_ value: String) throws {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw WebexCredentialError.emptyCredential }
        let data = Data(token.utf8)

        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw WebexCredentialError.keychain(updateStatus)
        }

        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(
                baseQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard retryStatus == errSecSuccess else {
                throw WebexCredentialError.keychain(retryStatus)
            }
            return
        }
        guard addStatus == errSecSuccess else {
            throw WebexCredentialError.keychain(addStatus)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw WebexCredentialError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
    }
}

enum WebexCredentialError: LocalizedError {
    case emptyCredential
    case invalidStoredCredential
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyCredential:
            return "Webexアクセストークンを入力してください。"
        case .invalidStoredCredential:
            return "Keychainに保存されたWebex認証情報を読み込めません。再認証してください。"
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String?
            return detail.map { "Webex認証情報をKeychainへ保存できません（\($0)）。" }
                ?? "Webex認証情報をKeychainへ保存できません（OSStatus \(status)）。"
        }
    }
}
