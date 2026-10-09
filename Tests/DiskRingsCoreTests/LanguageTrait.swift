import DiskRingsCore
import Testing

/// Feste Sprache für einen Test oder eine ganze Suite (`@Suite(.language("de"))`).
/// Setzt `L10n.override` als Task-Local; Texte und Formatierung (Locale der
/// Sprache) hängen damit nicht von der Systemsprache des Rechners ab.
struct FixedLanguage: TestTrait, SuiteTrait, TestScoping {
    let code: String

    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        try await L10n.$override.withValue(code) {
            try await function()
        }
    }
}

extension Trait where Self == FixedLanguage {
    static func language(_ code: String) -> Self { FixedLanguage(code: code) }
}
