import Foundation
import CryptoKit

// Signs an update-manifest message with the release machine's PRIVATE
// Ed25519 key (kept OUTSIDE the repo — ~/.clip-release/update-signing.key).
// The matching public key is baked into Updater.swift; the app refuses any
// manifest whose signature doesn't verify, so repo/Release write access
// alone can't push an update to installs.
//
//   swift Scripts/sign-update.swift <keyfile> "<sha256>|<build>|<url>"
//
// Prints the base64 signature on stdout.
let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: sign-update.swift <keyfile> <message>\n".utf8))
    exit(2)
}
guard let b64 = try? String(contentsOfFile: args[1], encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
      let raw = Data(base64Encoded: b64),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
    FileHandle.standardError.write(Data("sign-update: cannot read private key at \(args[1])\n".utf8))
    exit(1)
}
guard let sig = try? key.signature(for: Data(args[2].utf8)) else {
    FileHandle.standardError.write(Data("sign-update: signing failed\n".utf8))
    exit(1)
}
print(sig.base64EncodedString())
