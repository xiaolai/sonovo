import Foundation

package struct FolderIdentityRecord: Codable, Equatable, Sendable {
    package init(volumeUUID: String?, fileResourceIdentifier: String?, capturedAt: Date, provenance: Provenance) {
        self.volumeUUID = volumeUUID
        self.fileResourceIdentifier = fileResourceIdentifier
        self.capturedAt = capturedAt
        self.provenance = provenance
    }
    package enum Provenance: String, Codable, Sendable {
        case observed
    }

    package var volumeUUID: String?
    package var fileResourceIdentifier: String?
    package var capturedAt: Date
    package var provenance: Provenance
}

package enum FolderIdentity {
    package static func record(for url: URL) -> FolderIdentityRecord? {
        guard let values = try? url.resourceValues(forKeys: [
            .volumeUUIDStringKey,
            .fileResourceIdentifierKey
        ]) else {
            return nil
        }
        var resourceIdentifier: String?
        if let data = values.fileResourceIdentifier as? Data {
            resourceIdentifier = data.base64EncodedString()
        } else if let data = values.fileResourceIdentifier as? NSData {
            resourceIdentifier = (data as Data).base64EncodedString()
        }
        let volume = values.volumeUUIDString
        guard volume != nil || resourceIdentifier != nil else {
            return nil
        }
        return FolderIdentityRecord(
            volumeUUID: volume,
            fileResourceIdentifier: resourceIdentifier,
            capturedAt: Date(),
            provenance: .observed
        )
    }

    /// A positive match requires both halves. A missing or partial identity
    /// is not evidence and falls back to manual selection.
    package static func matches(
        _ first: FolderIdentityRecord,
        _ second: FolderIdentityRecord
    ) -> Bool {
        guard let firstVolume = first.volumeUUID,
              let secondVolume = second.volumeUUID,
              firstVolume == secondVolume,
              let firstResource = first.fileResourceIdentifier,
              let secondResource = second.fileResourceIdentifier,
              firstResource == secondResource else {
            return false
        }
        return true
    }
}
