import Foundation

package struct AppAlert: Identifiable, Equatable {
    package let id = UUID()
    package let title: String
    package let message: String
    package init(title: String, message: String) { self.title = title; self.message = message }
}
