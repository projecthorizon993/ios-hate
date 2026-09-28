package com.example.lumaframe.diagnostics

import android.content.Context
import com.example.lumaframe.support.AppLog
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Runs every probe off the main thread and assembles a [CapabilityReport].
 *
 * Deliberately depends on nothing but the probes, so the report can still be produced
 * when the camera, processing and ML layers are broken. That is exactly when it is
 * most useful.
 */
object CapabilityCollector {

    data class Outcome(
        val report: CapabilityReport,
        val logLines: List<String>
    )

    suspend fun collect(context: Context, logLimit: Int? = null): Outcome = withContext(Dispatchers.Default) {
        AppLog.note("capability probe: start")

        val sections = mutableListOf<ReportSection>()
        sections += PlatformProbe.sections(context)
        sections += CameraProbe.sections(context)
        sections += CameraXProbe.sections(context)
        sections += MlProbe.sections(context)
        sections += PlatformProbe.cpuBenchmark()

        val report = CapabilityReport(
            generatedAtMillis = System.currentTimeMillis(),
            platform = platformString(),
            summary = buildSummary(sections),
            sections = sections
        )

        val entryCount = sections.sumOf { it.entries.size }
        AppLog.note("capability probe: done, ${sections.size} sections, $entryCount entries")

        Outcome(report, AppLog.recentLines(logLimit))
    }

    /**
     * One line answering "what can this device actually do", so three reports can be
     * compared at a glance in a chat.
     */
    private fun buildSummary(sections: List<ReportSection>): String {
        val back = consensus("back camera count", sections) ?: "unknown"
        val raw = consensus("RAW", sections) ?: "unknown"
        val rawSensor = consensus("RAW_SENSOR", sections) ?: "unknown"
        val tenBit = consensus("per frame HDR (DYNAMIC_RANGE_TEN_BIT)", sections) ?: "unknown"
        val manual = consensus("MANUAL_SENSOR", sections) ?: "unknown"
        val gpu = consensus("GPU delegate", sections) ?: "unknown"
        return "back cameras: $back | MANUAL_SENSOR: $manual | RAW: $raw | RAW_SENSOR: $rawSensor | " +
            "10-bit HDR: $tenBit | GPU delegate: $gpu"
    }

    /**
     * The single value for [label], or `mixed` when cameras disagree. A per-camera
     * difference is more interesting than hiding it behind a yes or a no.
     */
    private fun consensus(label: String, sections: List<ReportSection>): String? {
        val values = sections.asSequence()
            .flatMap { it.entries.asSequence() }
            .filter { it.label == label }
            .map { it.value }
            .distinct()
            .toList()
        if (values.isEmpty()) return null
        if (values.size == 1) return values.first()
        // Keep it short: values can be long descriptive strings.
        return "mixed (${values.joinToString(" / ") { it.take(24) }})"
    }

    private fun platformString(): String = "Android ${android.os.Build.VERSION.RELEASE} " +
        "(API ${android.os.Build.VERSION.SDK_INT}, ${android.os.Build.MODEL})"
}
