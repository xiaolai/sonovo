"""Build-policy regressions; synthetic trees only, no app or compiler launch."""
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from design_token_rule import ui_source_files, theme_path
from stage_resources import stage_resources, ResourceStagingError


class ModuleBuildPolicyTests(unittest.TestCase):
    def test_package_access_does_not_hide_visual_constants(self):
        from check_design_tokens import scan_text
        self.assertTrue(scan_text("Feature.swift", "package static let rowPadding: CGFloat = 13"))

    def test_every_populated_ui_target_is_scanned(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("Sonovo", "SonovoDesignSystem", "SonovoViewerFeature"):
                source = root / "Sources" / name / "View.swift"
                source.parent.mkdir(parents=True)
                source.write_text("import SwiftUI\nstruct Bad: View { var body: some View { Text(\"x\").padding(13) } }")
            files = ui_source_files(root)
            self.assertEqual(len(files), 3)
            from check_design_tokens import scan_text
            self.assertTrue(all(scan_text(str(p), p.read_text()) for p in files))

    def test_unknown_ui_target_cannot_escape_policy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "Sources" / "UnregisteredFeature" / "View.swift"
            source.parent.mkdir(parents=True)
            source.write_text("import SwiftUI\n")
            with self.assertRaisesRegex(ValueError, "UnregisteredFeature"):
                ui_source_files(root)

    def test_populated_root_and_single_theme_are_required(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Sources" / "Sonovo").mkdir(parents=True)
            with self.assertRaisesRegex(ValueError, "empty"):
                ui_source_files(root)
            old = root / "Sources" / "Sonovo" / "Theme.swift"
            old.write_text("enum AppTheme {}")
            self.assertEqual(theme_path(root), old)
            new = root / "Sources" / "SonovoDesignSystem" / "Theme.swift"
            new.parent.mkdir()
            new.write_text(old.read_text())
            with self.assertRaisesRegex(ValueError, "exactly one"):
                theme_path(root)
            old.unlink()
            self.assertEqual(theme_path(root), new)

    def test_staging_copies_declared_bundles_and_skips_test_bundles(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            products, app = root / "products", root / "Sonovo.app"
            for name in ("Sonovo_Sonovo", "Sonovo_SonovoDiagramUI", "Sonovo_SonovoAppTests"):
                bundle = products / (name + ".bundle")
                bundle.mkdir(parents=True)
                (bundle / "fixture").write_text(name)
            manifest = {"name": "Sonovo", "targets": [
                {"name": "Sonovo", "type": "executable", "resources": [{"path": "Resources"}]},
                {"name": "SonovoDiagramUI", "type": "library", "resources": [{"path": "Resources"}]},
                {"name": "SonovoAppTests", "type": "test", "resources": [{"path": "Fixtures"}]}
            ]}
            names = stage_resources(products, app, manifest)
            self.assertEqual(set(names), {"Sonovo_Sonovo.bundle", "Sonovo_SonovoDiagramUI.bundle"})
            self.assertFalse((app / "Contents/Resources/Sonovo_SonovoAppTests.bundle").exists())
            self.assertTrue((app / "Contents/Resources/Sonovo_SonovoDiagramUI.bundle/fixture").exists())

    def test_staging_uses_product_closure_and_excludes_stale_and_test_helpers(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            products, app = root / "products", root / "Sonovo.app"
            for name in ["Sonovo_App.bundle", "Vendor_Fonts.bundle", "Sonovo_TestSupport.bundle", "Sonovo_OldTests.bundle", "OldVendor_TestFixtures.bundle"]:
                (products / name).mkdir(parents=True)
            manifest = {"name": "Sonovo", "products": [{"name": "App", "targets": ["App"]}], "targets": [
                {"name": "App", "type": "executable", "resources": [{}], "dependencies": [{"product": ["Fonts", "vendor", None, None]}]},
                {"name": "TestSupport", "type": "regular", "resources": [{}]}
            ], "_dependency_manifests": [{"identity": "vendor", "manifest": {
                "name": "Vendor", "products": [{"name": "Fonts", "targets": ["Fonts"]}],
                "targets": [{"name": "Fonts", "type": "regular", "resources": [{}]}]
            }}]}
            names = stage_resources(products, app, manifest)
            self.assertEqual(names, ["Sonovo_App.bundle", "Vendor_Fonts.bundle"])
            self.assertEqual(sorted(p.name for p in (app / "Contents/Resources").iterdir()), names)

    def test_missing_dependency_bundle_fails_before_staging(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = {"name": "Sonovo", "products": [{"name": "App", "targets": ["App"]}], "targets": [
                {"name": "App", "type": "executable", "dependencies": [{"product": ["Fonts", "vendor", None, None]}]}
            ], "_dependency_manifests": [{"identity": "vendor", "manifest": {
                "name": "Vendor", "products": [{"name": "Fonts", "targets": ["Fonts"]}],
                "targets": [{"name": "Fonts", "type": "regular", "resources": [{}]}]
            }}]}
            with self.assertRaisesRegex(ResourceStagingError, "Vendor_Fonts"):
                stage_resources(root / "products", root / "Sonovo.app", manifest)
            self.assertFalse((root / "Sonovo.app").exists())

    def test_missing_declared_bundle_fails_before_staging(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = {"name": "Sonovo", "targets": [
                {"name": "SonovoViewerFeature", "type": "library", "resources": [{"path": "Resources"}]}
            ]}
            with self.assertRaisesRegex(ResourceStagingError, "SonovoViewerFeature"):
                stage_resources(root / "products", root / "Sonovo.app", manifest)
            self.assertFalse((root / "Sonovo.app").exists())


if __name__ == "__main__":
    unittest.main()
