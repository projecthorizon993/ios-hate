package com.example.lumaframe.diagnostics

/** Severity of a single report line. The marker makes the report greppable. */
enum class ReportLevel(val marker: String) {
    INFO(""),
    GOOD("+"),
    NOTE("#"),
    WARN("!"),
    FAIL("x")
}

/** One measurement. `label` is stable so it can be compared across devices. */
data class ReportEntry(
    val label: String,
    val value: String,
    val level: ReportLevel = ReportLevel.INFO
) {
    constructor(label: String, value: Boolean) : this(
        label,
        if (value) "yes" else "no",
        if (value) ReportLevel.GOOD else ReportLevel.INFO
    )

    constructor(label: String, value: Boolean, level: ReportLevel) :
        this(label, if (value) "yes" else "no", level)

    /** Counts and identifiers are common in this report; keep the call sites readable. */
    constructor(label: String, value: Int, level: ReportLevel = ReportLevel.INFO) :
        this(label, value.toString(), level)
}

data class ReportSection(
    val title: String,
    val entries: MutableList<ReportEntry> = mutableListOf()
) {
    /** `section += entry` and `section += listOf(a, b)` both read naturally. */
    operator fun plusAssign(entry: ReportEntry) {
        entries += entry
    }

    operator fun plusAssign(more: List<ReportEntry>) {
        entries += more
    }
}

data class CapabilityReport(
    val generatedAtMillis: Long,
    val platform: String,
    val summary: String,
    val sections: List<ReportSection>
)

/**
 * Text rendering for a report. Free of Android types so the unit tests can run on the
 * JVM with no device and no Robolectric.
 */
object ReportText {

    const val ENTRY_INDENT = "  "

    fun entryLine(entry: ReportEntry): String {
        val prefix = if (entry.level.marker.isEmpty()) "" else entry.level.marker + " "
        return ENTRY_INDENT + prefix + entry.label + ": " + entry.value
    }

    fun sectionHeader(title: String): String = "\n== $title =="

    fun render(report: CapabilityReport, logLines: List<String> = emptyList()): String = buildString {
        append("LumaFrame Capability Report\n")
        append("platform: ${report.platform}\n")
        append("generated: ${stamp(report.generatedAtMillis)}\n")
        if (report.summary.isNotEmpty()) {
            append("summary: ${report.summary}\n")
        }
        for (section in report.sections) {
            append(sectionHeader(section.title)).append('\n')
            for (entry in section.entries) {
                append(entryLine(entry)).append('\n')
            }
        }
        if (logLines.isNotEmpty()) {
            append(sectionHeader("Recent log (${logLines.size} lines)")).append('\n')
            for (line in logLines) {
                append(ENTRY_INDENT).append(line).append('\n')
            }
        }
    }

    private val formatter: java.text.SimpleDateFormat =
        java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssZ", java.util.Locale.ROOT)

    fun stamp(millis: Long): String = synchronized(formatter) { formatter.format(millis) }
}

object ReportFormat {

    private val locale = java.util.Locale.ROOT

    fun number(value: Double, decimals: Int = 2): String {
        if (value == Math.floor(value) && !value.isInfinite()) {
            return value.toLong().toString()
        }
        return String.format(locale, "%.${decimals}f", value)
    }

    fun range(lower: Double, upper: Double): String = "${number(lower)} ... ${number(upper)}"

    /** `1/120` rather than `0.00833s`, because that is how a camera UI shows shutter speed. */
    fun shutter(seconds: Double): String {
        if (seconds <= 0.0) return "n/a"
        if (seconds >= 1.0) return String.format(locale, "%.1fs", seconds)
        val denominator = Math.round(1.0 / seconds)
        if (denominator < 1 || denominator >= 10000) return String.format(locale, "%.5fs", seconds)
        return "1/$denominator"
    }

    fun list(values: List<String>, empty: String = "none"): String =
        if (values.isEmpty()) empty else values.joinToString(", ")

    fun fourCC(code: Int): String {
        val bytes = byteArrayOf(
            (code shr 24 and 0xFF).toByte(),
            (code shr 16 and 0xFF).toByte(),
            (code shr 8 and 0xFF).toByte(),
            (code and 0xFF).toByte()
        )
        val text = bytes.joinToString("") { byte ->
            val value = byte.toInt() and 0xFF
            if (value in 0x20..0x7E) value.toChar().toString() else String.format(locale, "\\x%02X", value)
        }
        return "0x" + String.format(locale, "%08X", code) + " '" + text + "'"
    }

    fun duration(nanos: Long): Double = nanos.toDouble() / 1_000_000.0
}
