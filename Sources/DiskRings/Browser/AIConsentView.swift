import DiskRingsCore
import SwiftUI

/// Datenschutz-Hinweis vor dem ersten Senden an eine Web-KI bzw. dem Start
/// einer Sitzung: was übergeben wird, wer es erhält, was anonymisiert wird.
/// Weiter nur auf ausdrücklichen Klick; „Nicht mehr fragen“ lässt sich in den
/// Einstellungen (Reiter „KI“) zurücknehmen.
struct AIConsentView: View {
    let request: AIConsentRequest
    var onCancel: () -> Void
    var onContinue: (_ dontAskAgain: Bool) -> Void
    @ViewState private var dontAskAgain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                    .frame(width: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("ai.consent.title")).font(.headline)
                    Text(L("ai.consent.message", request.itemName))
                    Text(recipientText)
                    Label(L("ai.consent.anonymized"), systemImage: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            }
            Toggle(L("ai.consent.dontAsk"), isOn: $dontAskAgain)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            HStack {
                Spacer()
                Button(L("common.cancel"), role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(L("ai.consent.continue")) { onContinue(dontAskAgain) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var recipientText: String {
        switch request.action {
        case .session: L("ai.consent.session", request.action.recipientName)
        default: L("ai.consent.web", request.action.recipientName)
        }
    }
}
