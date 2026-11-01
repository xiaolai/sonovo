import Foundation

/// A replace-original request is addressed to one project document. Retained
/// editors for other projects must not consume it through a shared boolean.
package struct MediaReplaceRequest: Equatable, Sendable {
    package init(projectID: String, documentID: String) { self.projectID = projectID; self.documentID = documentID }
    package let projectID: String
    package let documentID: String
}


package struct MediaSeekRequest: Equatable, Sendable {
    package let path: String
    package let seconds: Double?
    package init(path: String, seconds: Double?) { self.path = path; self.seconds = seconds }
}
