/// Namespace for the testable Markdown core.
///
/// `SonovoCore` depends on Foundation and the system file APIs only. It never
/// imports AppKit or SwiftUI, so parser, document, file, and command tests run
/// without a window.
public enum SonovoCore {
    /// The minimum macOS version the core is built against.
    public static let minimumMacOSVersion = "26.0"
}
