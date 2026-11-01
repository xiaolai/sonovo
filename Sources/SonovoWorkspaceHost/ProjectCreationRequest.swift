import Foundation

package struct ProjectCreationRequest {
    package let root: URL
    package let expectedVolumeIdentifier: String?
    package var offlineReason: String?
    package init(root: URL, expectedVolumeIdentifier: String? = nil, offlineReason: String? = nil) {
        self.root = root; self.expectedVolumeIdentifier = expectedVolumeIdentifier; self.offlineReason = offlineReason
    }
}
