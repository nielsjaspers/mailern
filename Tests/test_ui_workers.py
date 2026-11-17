from pathlib import Path
import runpy
import unittest


timings = runpy.run_path(str(Path(__file__).resolve().parents[1] / "scripts/run-ui-workers.py"))["timings"]


class DurationCacheTests(unittest.TestCase):
    def test_reads_passed_ui_cases_and_sums_editor_methods(self):
        log = """
Test Case '-[MailernUITests.ComposerFileAttachmentUITests testComposerFileAttachment]' started.
    t = 0.01s Start Test
Test Case '-[MailernUITests.ComposerFileAttachmentUITests testComposerFileAttachment]' passed (76.047 seconds).
Test Case '-[MailernUITests.ComposerRevertedHeadersPersistAndStayProtectedUITests testComposerRevertedHeadersPersistAndStayProtected]' failed (84.907 seconds).
Test Case '-[MailernTests.ComposerEditorTests testBoldPreservesMixedFontSizesAndFamilies]' passed (0.250 seconds).
Test Case '-[MailernTests.ComposerEditorTests testMixedParagraphsKeepTheirOwnStyles]' passed (0.125 seconds).
"""
        self.assertEqual(timings(log), {
            "ComposerFileAttachmentUITests": 76.047,
            "MailernTests": 0.375,
        })


if __name__ == "__main__":
    unittest.main()
