// Ed25519 signing helper for the self-updater (CryptoKit, macOS only).
//
//   swift Scripts/sign-update.swift genkey
//       → prints a new PRIVATE key (base64) and its PUBLIC key (base64).
//         Store the private key as the repo secret UPDATE_SIGNING_KEY.
//
//   UPDATE_SIGNING_KEY=… swift Scripts/sign-update.swift sign CLIP.zip
//       → prints the base64 signature of the file.
//
//   UPDATE_SIGNING_KEY=… swift Scripts/sign-update.swift pubkey
//       → prints the public key for the private key in the environment.
//
// The app embeds the public key (Info.plist `CLIPUpdatePublicKey`, set by
// make-app.sh from UPDATE_PUBLIC_KEY) and refuses any update whose zip
// isn't signed by the matching private key.
import CryptoKit
import Foundation

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

func privateKeyFromEnv() -> Curve25519.Signing.PrivateKey {
    guard let b64 = ProcessInfo.processInfo.environment["UPDATE_SIGNING_KEY"],
          let raw = Data(base64Encoded: b64.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("UPDATE_SIGNING_KEY missing or not a base64 Ed25519 private key") }
    return key
}

let args = CommandLine.arguments
guard args.count >= 2 else { fail("usage: sign-update.swift genkey | pubkey | sign <file>") }

switch args[1] {
case "genkey":
    let key = Curve25519.Signing.PrivateKey()
    print("PRIVATE (secret UPDATE_SIGNING_KEY): \(key.rawRepresentation.base64EncodedString())")
    print("PUBLIC: \(key.publicKey.rawRepresentation.base64EncodedString())")
case "pubkey":
    print(privateKeyFromEnv().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard args.count >= 3 else { fail("usage: sign-update.swift sign <file>") }
    guard let data = FileManager.default.contents(atPath: args[2]) else { fail("cannot read \(args[2])") }
    let sig = try privateKeyFromEnv().signature(for: data)
    print(sig.base64EncodedString())
default:
    fail("unknown command \(args[1])")
}
