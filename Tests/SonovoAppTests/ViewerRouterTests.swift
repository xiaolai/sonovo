import XCTest
@testable import Sonovo

final class ViewerRouterTests: XCTestCase {
    func testRoutesDocumentExtensions() {
        XCTAssertEqual(ViewerRouter.route(forExtension: "pdf"), .pdf)
        XCTAssertEqual(ViewerRouter.route(forExtension: "SVG"), .localWeb)
        XCTAssertEqual(ViewerRouter.route(forExtension: "html"), .localWeb)
        XCTAssertEqual(ViewerRouter.route(forExtension: "png"), .image)
        XCTAssertEqual(ViewerRouter.route(forExtension: "webp"), .image)
        XCTAssertEqual(ViewerRouter.route(forExtension: "dng"), .image)
        XCTAssertEqual(ViewerRouter.route(forExtension: "docx"), .quickLook)
        XCTAssertEqual(ViewerRouter.route(forExtension: "psd"), .quickLook)
        XCTAssertEqual(ViewerRouter.route(forExtension: "zip"), .metadata)
        XCTAssertEqual(ViewerRouter.route(forExtension: "xyz"), .metadata)
    }

    func testEveryListedExtensionMapsToItsFamily() {
        for fileExtension in ViewerRouter.imageExtensions {
            XCTAssertEqual(
                ViewerRouter.route(forExtension: fileExtension),
                .image,
                fileExtension
            )
        }
        for fileExtension in ViewerRouter.webExtensions {
            XCTAssertEqual(
                ViewerRouter.route(forExtension: fileExtension),
                .localWeb,
                fileExtension
            )
        }
        for fileExtension in ViewerRouter.quickLookExtensions {
            XCTAssertEqual(
                ViewerRouter.route(forExtension: fileExtension),
                .quickLook,
                fileExtension
            )
        }
    }
}
