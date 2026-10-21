import WebKit
import XCTest
@testable import Sonovo

/// Optional Objective-C delegate methods are matched by exact signature. A
/// "nearly matches" warning silently leaves a method uncalled — this test makes
/// that invisible failure loud by checking the selectors the coordinator
/// actually exposes to WebKit.
@MainActor
final class ModelWebViewDelegateTests: XCTestCase {
    func testCoordinatorExposesEveryWebKitCallbackItReliesOn() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SonovoModelDelegateTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = directory.appendingPathComponent("model.stl")
        try Data("solid cube\n".utf8).write(to: model)

        let coordinator = ModelWebView.Coordinator(
            document: Model3DDocument(url: model, format: .stl)
        )

        let navigationSelectors: [Selector] = [
            Selector("webView:decidePolicyForNavigationAction:decisionHandler:"),
            Selector("webView:didFailNavigation:withError:"),
            Selector("webView:didFailProvisionalNavigation:withError:"),
            Selector("webViewWebContentProcessDidTerminate:")
        ]
        for selector in navigationSelectors {
            XCTAssertTrue(
                coordinator.responds(to: selector),
                "Missing WKNavigationDelegate method \(selector)"
            )
        }

        let uiSelectors: [Selector] = [
            Selector("webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:"),
            Selector("webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:"),
            Selector("webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:"),
            Selector("webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:"),
            Selector("webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:")
        ]
        for selector in uiSelectors {
            XCTAssertTrue(
                coordinator.responds(to: selector),
                "Missing WKUIDelegate method \(selector)"
            )
        }

        XCTAssertTrue(
            coordinator.responds(
                to: Selector("userContentController:didReceiveScriptMessage:")
            )
        )
    }
}
