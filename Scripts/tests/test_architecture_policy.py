from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from check_architecture import check_sources


class ArchitecturePolicyTests(unittest.TestCase):
    def scan(self, target, source, dependencies=()):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "Sources" / target / "Fixture.swift"
            path.parent.mkdir(parents=True)
            path.write_text(source)
            manifest = {"targets": [{"name": target, "type": "library", "target_dependencies": list(dependencies)}]}
            return check_sources(root, manifest)

    def test_component_test_target_cannot_depend_on_executable_or_host(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Sources").mkdir()
            path = root / "Tests/SonovoMarkdownFeatureTests/Fixture.swift"
            path.parent.mkdir(parents=True)
            path.write_text("import Sonovo\n")
            manifest = {"targets": [{"name": "SonovoMarkdownFeatureTests", "type": "test",
                                      "target_dependencies": ["SonovoMarkdownFeature", "Sonovo"]}]}
            self.assertTrue(check_sources(root, manifest))
            path.write_text("import SonovoMarkdownFeature\n")
            manifest["targets"][0]["target_dependencies"] = ["SonovoMarkdownFeature", "SonovoWorkspaceHost"]
            self.assertTrue(check_sources(root, manifest))
            manifest["targets"][0]["target_dependencies"] = ["SonovoMarkdownFeature"]
            self.assertFalse(check_sources(root, manifest))

    def test_headless_module_cannot_import_ui(self):
        self.assertTrue(self.scan("SonovoDocumentSupport", "import SwiftUI\n"))
        self.assertFalse(self.scan("SonovoDocumentSupport", "import Foundation\n"))

    def test_host_cannot_import_concrete_feature(self):
        errors = self.scan("SonovoWorkspaceHost", "import SonovoCodeFeature\n", ["SonovoCodeFeature"])
        self.assertTrue(any("SonovoCodeFeature" in e for e in errors))

    def test_host_cannot_name_a_concrete_workspace_or_builtin_id(self):
        self.assertTrue(self.scan("SonovoWorkspaceHost", "let document: CodeWorkspace\n"))
        self.assertTrue(self.scan("SonovoWorkspaceHost", 'let id = "builtin.code"\n'))

    def test_media_engine_is_also_headless(self):
        self.assertTrue(self.scan("SonovoMediaEngine", "import AppKit\n"))

    def test_sibling_feature_import_is_rejected(self):
        self.assertTrue(self.scan("SonovoCodeFeature", "import SonovoMarkdownFeature\n", ["SonovoMarkdownFeature"]))

    def test_undeclared_direct_dependency_is_rejected(self):
        self.assertTrue(self.scan("SonovoCodeFeature", "import SonovoFileIO\n"))
        self.assertFalse(self.scan("SonovoCodeFeature", "import SonovoFileIO\n", ["SonovoFileIO"]))

    def test_unknown_target_cannot_bypass_policy(self):
        self.assertTrue(self.scan("SonovoNewFeature", "import Foundation\n"))

    def test_unused_forbidden_manifest_dependency_is_also_rejected(self):
        self.assertTrue(self.scan("SonovoWorkspaceHost", "import Foundation\n", ["SonovoCodeFeature"]))


if __name__ == "__main__":
    unittest.main()
