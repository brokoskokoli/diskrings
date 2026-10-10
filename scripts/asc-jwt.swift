// Erzeugt ein JSON Web Token (ES256) für die App Store Connect API und gibt
// nur das Token auf stdout aus. Ohne Fremdpakete (CryptoKit).
//
//   ASC_KEY_PATH=AuthKey_XXXXXXXXXX.p8 ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=<uuid> \
//     swift scripts/asc-jwt.swift
//
// Optional: ASC_JWT_LIFETIME (Sekunden, Standard 1140 = 19 Minuten; Apple
// erlaubt höchstens 20 Minuten), ASC_JWT_NOW (Unix-Zeit, nur für Tests).
// Header: alg ES256, kid, typ JWT. Payload: iss, iat, exp, aud appstoreconnect-v1.
// https://developer.apple.com/documentation/appstoreconnectapi/generating-tokens-for-api-requests
//
// Fehler gehen nach stderr, ohne Inhalt des Schlüssels; Exit-Code 1.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("asc-jwt: \(message)\n".utf8))
    exit(1)
}

func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func json(_ object: [String: Any]) -> Data {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
        fail("JSON nicht erzeugbar")
    }
    return data
}

let env = ProcessInfo.processInfo.environment
guard let keyPath = env["ASC_KEY_PATH"], !keyPath.isEmpty else { fail("ASC_KEY_PATH fehlt") }
guard let keyID = env["ASC_KEY_ID"], !keyID.isEmpty else { fail("ASC_KEY_ID fehlt") }
guard let issuerID = env["ASC_ISSUER_ID"], !issuerID.isEmpty else { fail("ASC_ISSUER_ID fehlt") }

let lifetime = Int(env["ASC_JWT_LIFETIME"] ?? "") ?? 1140
guard lifetime > 0, lifetime <= 1200 else { fail("ASC_JWT_LIFETIME muss zwischen 1 und 1200 Sekunden liegen") }
let now = Int(env["ASC_JWT_NOW"] ?? "") ?? Int(Date().timeIntervalSince1970)

guard let pem = try? String(contentsOfFile: keyPath, encoding: .utf8) else {
    fail("Schlüsseldatei nicht lesbar: \(keyPath)")
}
let key: P256.Signing.PrivateKey
do {
    key = try P256.Signing.PrivateKey(pemRepresentation: pem)
} catch {
    fail("Schlüsseldatei ist kein P-256-Schlüssel im PEM-Format (.p8)")
}

let header = json(["alg": "ES256", "kid": keyID, "typ": "JWT"])
let payload = json(["iss": issuerID, "iat": now, "exp": now + lifetime, "aud": "appstoreconnect-v1"])
let signingInput = base64URL(header) + "." + base64URL(payload)
guard let signature = try? key.signature(for: Data(signingInput.utf8)) else { fail("Signieren fehlgeschlagen") }
// JWS verlangt die rohe Signatur r||s (64 Bytes), nicht DER.
print(signingInput + "." + base64URL(signature.rawRepresentation))
