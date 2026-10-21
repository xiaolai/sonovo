import Foundation
import XCTest
@testable import Sonovo

@MainActor
final class BlenderConverterTests: XCTestCase {
    private var temporaryDirectories: [URL] = []
    private var converters: [BlenderConverter] = []

    override func tearDown() {
        for converter in converters {
            converter.terminateAll()
        }
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        converters = []
        temporaryDirectories = []
        super.tearDown()
    }

    func testLocatorPrefersExplicitPath() throws {
        let executable = try makeExecutable(script: "#!/bin/sh\nexit 0\n")
        let locator = BlenderLocator(
            environment: ["SONOVO_BLENDER_PATH": executable.path],
            applicationURL: { nil }
        )
        XCTAssertEqual(
            locator.locate()?.executableURL,
            executable.standardizedFileURL
        )
    }

    func testLocatorSearchesPathAndCanReportMissing() throws {
        let directory = try makeDirectory()
        let executable = directory.appendingPathComponent("blender")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let pathLocator = BlenderLocator(
            environment: ["PATH": directory.path],
            applicationURL: { nil },
            includeStandardLocations: false
        )
        XCTAssertEqual(
            pathLocator.locate()?.executableURL,
            executable.standardizedFileURL
        )

        let missing = BlenderLocator(
            environment: [:],
            applicationURL: { nil },
            includeStandardLocations: false
        )
        XCTAssertNil(missing.locate())
    }

    func testSuccessfulConversionValidatesOutputAndInvocation() async throws {
        let directory = try makeDirectory()
        let argumentsDump = directory.appendingPathComponent("args.txt")
        let environmentDump = directory.appendingPathComponent("env.txt")
        let executable = try makeExecutable(
            script: """
            #!/bin/sh
            printf '%s\\n' "$@" > "\(argumentsDump.path)"
            env > "\(environmentDump.path)"
            printf 'glTF\\002\\000\\000\\000\\060\\000\\000\\000\\034\\000\\000\\000JSON{"asset":{"version":"2.0"}} ' > "$SONOVO_BLEND_OUTPUT"
            echo "Blender 5.2.2 LTS"
            echo "SONOVO_EXPORT_OK"
            """
        )
        let script = try makeReadableFile(name: "convert.py", text: "pass")
        let blend = try makeReadableFile(name: "scene.blend", text: "BLENDER")
        let converter = makeConverter(
            executable: executable,
            script: script,
            timeout: "30"
        )

        let result = try await converter.convert(source: blend)
        XCTAssertEqual(result.version, "5.2.2")
        XCTAssertTrue(result.log.contains("SONOVO_EXPORT_OK"))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: result.outputURL.path
            )
        )
        XCTAssertEqual(
            result.temporaryDirectory.deletingLastPathComponent().path,
            Model3DTemporaryFiles.root.path
        )
        temporaryDirectories.append(result.temporaryDirectory)

        let arguments = try String(
            contentsOf: argumentsDump,
            encoding: .utf8
        )
        XCTAssertTrue(arguments.contains("--background"))
        XCTAssertTrue(arguments.contains("--factory-startup"))
        XCTAssertTrue(arguments.contains("--disable-autoexec"))
        XCTAssertTrue(arguments.contains("--python-exit-code\n1"))
        XCTAssertTrue(arguments.contains("--python\n\(script.path)"))

        let environment = try String(
            contentsOf: environmentDump,
            encoding: .utf8
        )
        XCTAssertTrue(environment.contains("SONOVO_BLEND_INPUT=\(blend.path)"))
        XCTAssertTrue(environment.contains("SONOVO_BLEND_OUTPUT="))
        XCTAssertTrue(environment.contains("TMPDIR=\(result.temporaryDirectory.path)"))
        XCTAssertTrue(environment.contains("HOME=\(result.temporaryDirectory.path)"))
        XCTAssertFalse(environment.contains("SONOVO_SECRET_MARKER"))
    }

    func testVersionMarkerSurvivesAVerboseLog() async throws {
        let executable = try makeExecutable(
            script: """
            #!/bin/sh
            printf 'glTF\\002\\000\\000\\000\\060\\000\\000\\000\\034\\000\\000\\000JSON{"asset":{"version":"2.0"}} ' > "$SONOVO_BLEND_OUTPUT"
            echo "Blender 5.2.2 LTS"
            i=0
            while [ "$i" -lt 400 ]; do
                echo "export progress: a padding line that pushes the banner out"
                i=$((i + 1))
            done
            echo "SONOVO_BLENDER_VERSION=5.2.2"
            echo "SONOVO_EXPORT_OK"
            """
        )
        let script = try makeReadableFile(name: "convert.py", text: "pass")
        let blend = try makeReadableFile(name: "scene.blend", text: "BLENDER")
        let converter = makeConverter(executable: executable, script: script)

        let result = try await converter.convert(source: blend)
        temporaryDirectories.append(result.temporaryDirectory)
        XCTAssertFalse(
            result.log.contains("LTS"),
            "The banner must be pushed out of the retained tail for this test"
        )
        XCTAssertEqual(result.version, "5.2.2")
    }

    func testNonZeroExitFailsAndCleansTemporaryDirectory() async throws {
        let executable = try makeExecutable(script: "#!/bin/sh\nexit 7\n")
        let script = try makeReadableFile(name: "convert.py", text: "pass")
        let blend = try makeReadableFile(name: "scene.blend", text: "BLENDER")
        let converter = makeConverter(executable: executable, script: script)
        let before = try conversionDirectoryNames()

        do {
            _ = try await converter.convert(source: blend)
            XCTFail("Expected the conversion to fail")
        } catch let error as BlenderConversionError {
            guard case .failed(let status, _) = error else {
                return XCTFail("Expected failed status, got \(error)")
            }
            XCTAssertEqual(status, 7)
        }
        XCTAssertTrue(try conversionDirectoryNames().subtracting(before).isEmpty)
    }

    func testMissingSentinelIsRejectedEvenWithZeroExit() async throws {
        let executable = try makeExecutable(
            script: """
            #!/bin/sh
            printf 'glTF\\002\\000\\000\\000\\060\\000\\000\\000\\034\\000\\000\\000JSON{"asset":{"version":"2.0"}} ' > "$SONOVO_BLEND_OUTPUT"
            exit 0
            """
        )
        let script = try makeReadableFile(name: "convert.py", text: "pass")
        let blend = try makeReadableFile(name: "scene.blend", text: "BLENDER")
        let converter = makeConverter(executable: executable, script: script)
        let before = try conversionDirectoryNames()

        do {
            _ = try await converter.convert(source: blend)
            XCTFail("Expected the conversion to fail")
        } catch let error as BlenderConversionError {
            guard case .failed(0, _) = error else {
                return XCTFail("Expected failed status, got \(error)")
            }
        }
        XCTAssertTrue(try conversionDirectoryNames().subtracting(before).isEmpty)
    }

    func testHeaderOnlyGLBIsRejected() async throws {
        let executable = try makeExecutable(
            script: """
            #!/bin/sh
            printf 'glTF\\002\\000\\000\\000\\014\\000\\000\\000' > "$SONOVO_BLEND_OUTPUT"
            echo "SONOVO_EXPORT_OK"
            exit 0
            """
        )
        let script = try makeReadableFile(name: "convert.py", text: "pass")
        let blend = try makeReadableFile(name: "scene.blend", text: "BLENDER")
        let converter = makeConverter(executable: executable, script: script)

        do {
            _ = try await converter.convert(source: blend)
            XCTFail("Expected the conversion to fail")
        } catch let error as BlenderConversionError {
            guard case .invalidOutput = error else {
                return XCTFail("Expected invalid output, got \(error)")
            }
        }
    }

    func testMalformedGLBJSONIsRejected() async throws {
        let executable = try makeExecutable(
            script: """
            #!/bin/sh
            printf 'glTF\\002\\000\\000\\000\\030\\000\\000\\000\\004\\000\\000\\000JSON{   ' > "$SONOVO_BLEND_OUTPUT"
            echo "SONOVO_EXPORT_OK"
            exit 0
            """
        )
        let script = try makeReadableFile(name: "convert.py", text: "pass")
        let blend = try makeReadableFile(name: "scene.blend", text: "BLENDER")
        let converter = makeConverter(executable: executable, script: script)

        do {
            _ = try await converter.convert(source: blend)
            XCTFail("Expected the conversion to fail")
        } catch let error as BlenderConversionError {
            guard case .invalidOutput = error else {
                return XCTFail("Expected invalid output, got \(error)")
            }
        }
    }

    func testChunkExtendingPastTheFileIsRejected() async throws {
        let executable = try makeExecutable(
            script: """
            #!/bin/sh
            printf 'glTF\\002\\000\\000\\000\\030\\000\\000\\000\\144\\000\\000\\000JSON{}  ' > "$SONOVO_BLEND_OUTPUT"
            echo "SONOVO_EXPORT_OK"
            exit 0
            """
        )
        let script = try makeReadableFile(name: "convert.py", text: "pass")
        let blend = try makeReadableFile(name: "scene.blend", text: "BLENDER")
        let converter = makeConverter(executable: executable, script: script)

        do {
            _ = try await converter.convert(source: blend)
            XCTFail("Expected the conversion to fail")
        } catch let error as BlenderConversionError {
            guard case .invalidOutput = error else {
                return XCTFail("Expected invalid output, got \(error)")
            }
        }
    }

    func testInvalidGLBIsRejected() async throws {
        let executable = try makeExecutable(
            script: """
            #!/bin/sh
            printf 'nope' > "$SONOVO_BLEND_OUTPUT"
            echo "SONOVO_EXPORT_OK"
            exit 0
            """
        )
        let script = try makeReadableFile(name: "convert.py", text: "pass")
        let blend = try makeReadableFile(name: "scene.blend", text: "BLENDER")
        let converter = makeConverter(executable: executable, script: script)
        let before = try conversionDirectoryNames()

        do {
            _ = try await converter.convert(source: blend)
            XCTFail("Expected the conversion to fail")
        } catch let error as BlenderConversionError {
            guard case .invalidOutput = error else {
                return XCTFail("Expected invalid output, got \(error)")
            }
        }
        XCTAssertTrue(try conversionDirectoryNames().subtracting(before).isEmpty)
    }

    func testTimeoutTerminatesProcess() async throws {
        let executable = try makeExecutable(script: "#!/bin/sh\nexec sleep 20\n")
        let script = try makeReadableFile(name: "convert.py", text: "pass")
        let blend = try makeReadableFile(name: "scene.blend", text: "BLENDER")
        let converter = makeConverter(
            executable: executable,
            script: script,
            timeout: "1"
        )
        let before = try conversionDirectoryNames()

        do {
            _ = try await converter.convert(source: blend)
            XCTFail("Expected a timeout")
        } catch let error as BlenderConversionError {
            guard case .timedOut = error else {
                return XCTFail("Expected timeout, got \(error)")
            }
        }
        XCTAssertTrue(try conversionDirectoryNames().subtracting(before).isEmpty)
    }

    func testCancellationTerminatesProcess() async throws {
        let executable = try makeExecutable(script: "#!/bin/sh\nexec sleep 20\n")
        let script = try makeReadableFile(name: "convert.py", text: "pass")
        let blend = try makeReadableFile(name: "scene.blend", text: "BLENDER")
        let converter = makeConverter(executable: executable, script: script)
        let before = try conversionDirectoryNames()

        let task = Task {
            try await converter.convert(source: blend)
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertTrue(try conversionDirectoryNames().subtracting(before).isEmpty)
    }

    func testFidelityMarkersBecomeWarnings() {
        let warnings = BlenderConverter.warnings(from: """
        Read blend
        SONOVO_SHAPE_KEYS=1
        SONOVO_SCENES=3
        SONOVO_PROCEDURAL_MATERIALS=2
        SONOVO_EXPORT_OK
        """)
        XCTAssertEqual(warnings.count, 3)
        XCTAssertTrue(warnings.contains {
            $0.contains("Shape keys were preserved")
        })
        XCTAssertTrue(warnings.contains {
            $0.contains("3 scenes")
        })
        XCTAssertTrue(warnings.contains {
            $0.contains("2 materials use procedural nodes")
        })

        XCTAssertTrue(
            BlenderConverter.warnings(from: """
            SONOVO_SHAPE_KEYS=0
            SONOVO_SCENES=1
            SONOVO_PROCEDURAL_MATERIALS=0
            SONOVO_EXPORT_OK
            """).isEmpty
        )
    }

    func testMissingExecutableIsReportedBeforeSpawning() async throws {
        let script = try makeReadableFile(name: "convert.py", text: "pass")
        let blend = try makeReadableFile(name: "scene.blend", text: "BLENDER")
        let locator = BlenderLocator(
            environment: ["SONOVO_BLENDER_PATH": "/nonexistent/blender"],
            applicationURL: { nil },
            includeStandardLocations: false
        )
        XCTAssertNil(locator.locate())
        let converter = BlenderConverter(
            environment: ["SONOVO_BLENDER_PATH": "/nonexistent/blender"],
            scriptURL: script,
            locator: locator
        )
        converters.append(converter)

        do {
            _ = try await converter.convert(source: blend)
            XCTFail("Expected not installed")
        } catch let error as BlenderConversionError {
            guard case .notInstalled = error else {
                return XCTFail("Expected notInstalled, got \(error)")
            }
        }
    }

    // MARK: - Helpers

    private func makeConverter(
        executable: URL,
        script: URL,
        timeout: String = "30"
    ) -> BlenderConverter {
        let locator = BlenderLocator(
            environment: ["SONOVO_BLENDER_PATH": executable.path],
            applicationURL: { nil }
        )
        let converter = BlenderConverter(
            environment: [
                "SONOVO_BLENDER_PATH": executable.path,
                "SONOVO_BLENDER_TIMEOUT_SECONDS": timeout,
                "SONOVO_SECRET_MARKER": "should-not-leak"
            ],
            scriptURL: script,
            locator: locator
        )
        converters.append(converter)
        return converter
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SonovoBlenderTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        temporaryDirectories.append(directory)
        return directory
    }

    private func makeExecutable(script: String) throws -> URL {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("fake-blender")
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
        return url
    }

    private func makeReadableFile(name: String, text: String) throws -> URL {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func conversionDirectoryNames() throws -> Set<String> {
        let root = Model3DTemporaryFiles.root
        guard FileManager.default.fileExists(atPath: root.path) else {
            return []
        }
        return Set(
            try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent)
        )
    }
}
