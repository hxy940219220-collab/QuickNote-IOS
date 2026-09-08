import Foundation
import Security

// Only operates on an isolated, synthetic item; never reads QuickNote credentials.
guard CommandLine.arguments.count == 3,
      CommandLine.arguments[2].hasPrefix("com.xixi.quicknote.signing-test.") else { exit(64) }
let operation = CommandLine.arguments[1]
let service = CommandLine.arguments[2]
var query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: "synthetic-upgrade-check"
]
guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { exit(65) }
let expected = Data("non-secret-upgrade-fixture".utf8)
var status: OSStatus
switch operation {
case "create":
    query[kSecValueData as String] = expected
    status = SecItemAdd(query as CFDictionary, nil)
case "read":
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecSuccess && item as? Data != expected { status = errSecDecode }
case "delete":
    status = SecItemDelete(query as CFDictionary)
case "update":
    status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: expected] as CFDictionary)
default: exit(64)
}
#if SECOND_BUILD
let version = 2
#else
let version = 1
#endif
print("build=\(version) operation=\(operation) status=\(status)")
exit(status == errSecSuccess ? 0 : 1)
