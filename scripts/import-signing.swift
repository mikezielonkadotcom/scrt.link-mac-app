// Import PKCS#12 without putting its password in command arguments or output.
// This is used only in the disposable GitHub-hosted signing runner.
import Foundation
import Security

func fail(_ operation: String, _ status: OSStatus = errSecParam) -> Never {
    fputs("\(operation) failed (Security status \(status)).\n", stderr)
    exit(1)
}

let environment = ProcessInfo.processInfo.environment
guard environment["GITHUB_ACTIONS"] == "true",
      let path = environment["NOTARY_KEYCHAIN"],
      let certificatePath = environment["CI_CERTIFICATE_PATH"],
      let password = environment["APPLE_CERTIFICATE_PASSWORD"], !password.isEmpty,
      let certificate = try? Data(contentsOf: URL(fileURLWithPath: certificatePath)) else {
    fail("Signing input validation")
}

var keychain: SecKeychain?
var status = SecKeychainOpen(path, &keychain)
guard status == errSecSuccess, let keychain else { fail("Keychain open", status) }

var codesign: SecTrustedApplication?
status = SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &codesign)
guard status == errSecSuccess, let codesign else { fail("Trusted application", status) }
var access: SecAccess?
status = SecAccessCreate("ScrtLink CI signing" as CFString, [codesign] as CFArray, &access)
guard status == errSecSuccess, let access else { fail("Signing access", status) }

let options = [
    kSecImportExportPassphrase as String: password,
    kSecImportExportKeychain as String: keychain,
    kSecImportExportAccess as String: access
] as CFDictionary
var imported: CFArray?
status = SecPKCS12Import(certificate as CFData, options, &imported)
guard status == errSecSuccess, let imported, CFArrayGetCount(imported) > 0 else {
    fail("Certificate import", status)
}
print("Signing certificate imported into the temporary Keychain.")
