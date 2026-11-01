import Foundation

package enum ReferenceDeliveryOutcome: Equatable {
    case sent
    case copied
    case rejected
}

/// Delivers a one-line code reference.
///
/// The terminal receives only sanitized text: C0/C1 controls and newlines are
/// stripped, and Enter is never appended. A multiline selection goes to the
/// clipboard instead. When the terminal sink refuses (hidden, gone, or owned
/// by another project), the reference is copied and the user is told.
package struct TerminalReferenceDelivery {
    package init(send: ((String) -> Bool)?, copy: @escaping (String) -> Void) {
        self.send = send
        self.copy = copy
    }

    package var send: ((String) -> Bool)?
    package var copy: (String) -> Void

    package static func sanitized(_ text: String) -> String? {
        let filtered = text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        let result = String(String.UnicodeScalarView(filtered))
            .trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? nil : result
    }

    package func deliver(reference: String, multiline: Bool) -> ReferenceDeliveryOutcome {
        if multiline {
            copy(reference)
            return .copied
        }
        guard let clean = Self.sanitized(reference) else {
            return .rejected
        }
        if let send, send(clean) {
            return .sent
        }
        copy(clean)
        return .copied
    }
}


@MainActor package struct TerminalReferenceService {
    package let recipientTitle: () -> String?
    package let delivery: () -> TerminalReferenceDelivery
    package init(recipientTitle: @escaping () -> String?, delivery: @escaping () -> TerminalReferenceDelivery) {
        self.recipientTitle = recipientTitle
        self.delivery = delivery
    }
}
