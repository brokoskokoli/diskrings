// Ed25519-Hilfen für die Sparkle-Updates, ohne Fremdpakete (CryptoKit).
//
//   swiftc -O scripts/sparkle-ed25519.swift -o <bin>
//   <bin> verify <öffentlicher Schlüssel, base64> <Signatur, base64> <Datei>
//       Exit 0, wenn die Signatur (von Sparkles sign_update) zur Datei und zum
//       Schlüssel passt; sonst 1. So prüft der Release-Workflow, dass das
//       Update-Archiv mit dem Schlüssel verifiziert, der in der App steht
//       (Resources/sparkle-public-ed-key.txt), bevor appcast.xml entsteht.
//   <bin> public-key
//       Liest einen privaten Schlüssel im Format von `generate_keys -x`
//       (base64 des 32-Byte-Seeds) von stdin und gibt den öffentlichen
//       Schlüssel (base64) aus. Für Tests und den Abgleich mit dem Secret.
//
// Der private Schlüssel kommt nur über stdin, nie als Argument; Fehler gehen
// ohne Schlüsselinhalt nach stderr.
import CryptoKit
import Foundation

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("sparkle-ed25519: \(message)\n".utf8))
    exit(code)
}

func decode(_ text: String, what: String) -> Data {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = Data(base64Encoded: trimmed) else { fail("\(what) ist kein base64") }
    return data
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "verify":
    guard args.count == 5 else { fail("Aufruf: verify <public-key> <signature> <file>") }
    let keyData = decode(args[2], what: "Öffentlicher Schlüssel")
    let signature = decode(args[3], what: "Signatur")
    guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
        fail("Öffentlicher Schlüssel hat nicht 32 Byte")
    }
    guard let file = FileManager.default.contents(atPath: args[4]) else { fail("Datei nicht lesbar: \(args[4])") }
    if key.isValidSignature(signature, for: file) {
        print("ok")
        exit(0)
    }
    fail("Signatur passt nicht zu Datei und öffentlichem Schlüssel", code: 1)
case "public-key":
    let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    let seed = decode(input, what: "Privater Schlüssel")
    guard seed.count == 32, let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
        fail("Privater Schlüssel ist kein 32-Byte-Seed (altes Format von generate_keys?)")
    }
    print(key.publicKey.rawRepresentation.base64EncodedString())
default:
    fail("Aufruf: verify <public-key> <signature> <file> | public-key < key")
}
