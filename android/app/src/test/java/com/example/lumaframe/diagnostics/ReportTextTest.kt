package com.example.lumaframe.diagnostics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Lean tests for the parts of the report that have arithmetic in them. Camera probing
 * is verified on device through the report, not here.
 */
class ReportTextTest {

    private fun report(sections: List<ReportSection>, summary: String = "") = CapabilityReport(
        generatedAtMillis = 0L,
        platform = "Android 15 (API 35, SM-G998B)",
        summary = summary,
        sections = sections
    )

    @Test
    fun infoEntryHasNoMarker() {
        assertEquals(
            "  back camera count: 4",
            ReportText.entryLine(ReportEntry("back camera count", "4"))
        )
    }

    @Test
    fun severityMarkersAreGreppable() {
        assertEquals("  + RAW: yes", ReportText.entryLine(ReportEntry("RAW", "yes", ReportLevel.GOOD)))
        assertEquals("  ! NNAPI: not used", ReportText.entryLine(ReportEntry("NNAPI", "not used", ReportLevel.WARN)))
        assertEquals("  x session: crashed", ReportText.entryLine(ReportEntry("session", "crashed", ReportLevel.FAIL)))
        assertEquals("  # note: hint", ReportText.entryLine(ReportEntry("note", "hint", ReportLevel.NOTE)))
    }

    @Test
    fun booleanSecondaryConstructorMapsLevels() {
        assertEquals(ReportLevel.GOOD, ReportEntry("flash", true).level)
        assertEquals(ReportLevel.INFO, ReportEntry("flash", false).level)
        assertEquals("yes", ReportEntry("flash", true).value)
        assertEquals("no", ReportEntry("flash", false).value)
    }

    @Test
    fun renderIncludesHeaderSectionsAndLog() {
        val text = ReportText.render(
            report(
                sections = listOf(
                    ReportSection("Device").apply { += ReportEntry("model", "SM-G998B") },
                    ReportSection("Camera2 overview").apply { += ReportEntry("back camera count", "4") }
                ),
                summary = "back cameras: 4"
            ),
            logLines = listOf("ml #1 gpu 4.10ms")
        )

        assertTrue(text.startsWith("LumaFrame Capability Report"))
        assertTrue(text.contains("platform: Android 15 (API 35, SM-G998B)"))
        assertTrue(text.contains("summary: back cameras: 4"))
        assertTrue(text.contains("== Device =="))
        assertTrue(text.contains("== Camera2 overview =="))
        assertTrue(text.contains("  model: SM-G998B"))
        assertTrue(text.contains("== Recent log (1 lines) =="))
        assertTrue(text.contains("ml #1 gpu 4.10ms"))
    }

    @Test
    fun renderOmitsLogSectionWhenEmpty() {
        assertFalse(ReportText.render(report(emptyList()), logLines = emptyList()).contains("Recent log"))
    }

    @Test
    fun shutterFormatsAsFractionBelowOneSecond() {
        assertEquals("1/120", ReportFormat.shutter(0.0083333))
        assertEquals("1/2", ReportFormat.shutter(0.5))
        assertEquals("1.5s", ReportFormat.shutter(1.5))
        assertEquals("n/a", ReportFormat.shutter(0.0))
    }

    @Test
    fun numberDropsTrailingZeroesButKeepsDecimals() {
        assertEquals("400", ReportFormat.number(400.0))
        assertEquals("1.25", ReportFormat.number(1.25))
        assertEquals("0", ReportFormat.number(0.0))
    }

    @Test
    fun fourCcRendersNonPrintableBytesAsHex() {
        assertEquals("BA81", ReportFormat.fourCC(0x42413831))
        // 0x000000FF is three control bytes plus 0xFF; none may leak through raw.
        assertTrue(ReportFormat.fourCC(0x000000FF).endsWith("????'"))
    }
}
