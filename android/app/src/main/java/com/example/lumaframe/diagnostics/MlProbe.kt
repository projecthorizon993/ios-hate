package com.example.lumaframe.diagnostics

import android.content.Context
import com.example.lumaframe.diagnostics.PlatformProbe.SocVendor
import com.example.lumaframe.support.AppLog
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.withContext
import org.tensorflow.lite.Interpreter
import org.tensorflow.lite.gpu.CompatibilityList
import org.tensorflow.lite.gpu.GpuDelegate
import java.nio.ByteBuffer
import java.util.concurrent.Executors

/**
 * LiteRT backend probe.
 *
 * Established facts this file is built around, all from official docs and checked in
 * September 2026 (docs/ARCHITECTURE.md section 2.2):
 *
 * - **NNAPI is deprecated as of Android 15.** It is not used here and will not be.
 * - **Google Play services TFLite ships GPU and XNNPACK only.** There is no NPU delegate
 *   in that package.
 * - NPU delegates are **vendor-specific**: Qualcomm AI Engine Direct, MediaTek
 *   NeuroPilot, Intel OpenVINO, Google Tensor. Samsung System LSI / Exynos AI LiteCore
 *   was still listed as "coming soon".
 * - LiteRT Maven **v2 exposes the Interpreter API as CPU only**; the documented
 *   Interpreter + `GpuDelegate` path is v1. The build pins 1.4.2.
 *
 * So on an Exynos 2100 Galaxy S21 Ultra there is realistically no NPU path today, and
 * the report says exactly that rather than implying one exists.
 */
object MlProbe {

    /** Optional asset. When it is absent the timing section reports that, not a guess. */
    const val MODEL_ASSET = "models/benchmark.tflite"
    const val ITERATIONS = 10

    private val vendorDelegates = listOf(
        Triple(SocVendor.QUALCOMM, "Qualcomm AI Engine Direct", "com.qualcomm.ai.engine.tflite.QualcommDelegate"),
        Triple(SocVendor.MEDIATEK, "MediaTek NeuroPilot", "com.mediatek.neuropilotextension.tflite.NeuroPilotDelegate"),
        Triple(SocVendor.INTEL, "Intel OpenVINO", "com.intel.openvino.tflite.OpenVINODelegate"),
        Triple(SocVendor.SAMSUNG, "Samsung Exynos AI LiteCore", "com.samsung.litert.core.CoreDelegate"),
        Triple(SocVendor.GOOGLE, "Google Tensor", "com.google.ai.edge.litert.tensor.Delegate")
    )

    /**
     * The GPU delegate must be created and invoked on the same thread, so the whole
     * benchmark is confined to one thread instead of a dispatcher that may hop.
     */
    private val singleThread: CoroutineDispatcher =
        Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "litert-probe") }
            .asCoroutineDispatcher()

    suspend fun sections(context: Context): List<ReportSection> = withContext(singleThread) {
        listOf(backendSection(context), benchmarkSection(context))
    }

    // MARK: - Backends

    private fun backendSection(context: Context): ReportSection {
        val section = ReportSection("LiteRT backends")
        val vendor = PlatformProbe.socVendor()

        section += ReportEntry("SoC vendor classification", vendor.label,
            if (vendor == SocVendor.OTHER) ReportLevel.WARN else ReportLevel.GOOD)

        // Proves the artifacts are on the classpath, independent of any model.
        for (className in listOf(
            "org.tensorflow.lite.Interpreter",
            "org.tensorflow.lite.gpu.CompatibilityList",
            "org.tensorflow.lite.gpu.GpuDelegate"
        )) {
            val present = classPresent(className)
            section += ReportEntry("class on classpath: $className", present, present)
        }

        val gpuSupported = gpuDelegateSupported()
        section += ReportEntry("GPU delegate", gpuSupportText(),
            if (gpuSupported) ReportLevel.GOOD else ReportLevel.FAIL)

        for ((delegateVendor, label, className) in vendorDelegates) {
            val present = classPresent(className)
            val level = when {
                present -> ReportLevel.GOOD
                delegateVendor == vendor -> ReportLevel.WARN
                else -> ReportLevel.INFO
            }
            section += ReportEntry("NPU delegate: $label",
                if (present) "on classpath" else "not bundled", level)
        }

        section += ReportEntry("candidate NPU delegate for this SoC", vendor.npuDelegate ?: "none",
            if (vendor.npuDelegate == null) ReportLevel.WARN else ReportLevel.NOTE)
        section += ReportEntry("Google Play services present",
            context.hasPackage("com.google.android.gms"), ReportLevel.NOTE)
        section += ReportEntry("NNAPI", "not used. Deprecated as of Android 15.", ReportLevel.WARN)
        section += ReportEntry("note",
            "An unavailable NPU is a normal outcome, not a failure: the ML layer falls back to " +
                "GPU, then to CPU with a reduced cadence.", ReportLevel.NOTE)
        return section
    }

    private fun classPresent(className: String): Boolean = try {
        Class.forName(className)
        true
    } catch (error: Throwable) {
        false
    }

    private fun gpuDelegateSupported(): Boolean = try {
        CompatibilityList().isDelegateSupportedOnThisDevice
    } catch (error: Throwable) {
        AppLog.fail("CompatibilityList probe failed", error)
        false
    }

    private fun gpuSupportText(): String = try {
        val list = CompatibilityList()
        if (list.isDelegateSupportedOnThisDevice) {
            "supported (${list.bestOptionsForThisDevice.deviceName})"
        } else {
            "not supported on this device"
        }
    } catch (error: Throwable) {
        "probe failed: ${error.message}"
    }

    // MARK: - Benchmark

    private fun benchmarkSection(context: Context): ReportSection {
        val section = ReportSection("LiteRT benchmark")

        val modelBytes = try {
            context.assets.open(MODEL_ASSET).use { it.readBytes() }
        } catch (error: Throwable) {
            section += ReportEntry("benchmark model", "not present at assets/$MODEL_ASSET", ReportLevel.WARN)
            section += ReportEntry("benchmark note",
                "Step 0 ships without a model on purpose. Add one and rerun; the report then " +
                    "compares CPU and GPU timings. Backend availability above is real either way.",
                ReportLevel.NOTE)
            return section
        }

        section += ReportEntry("benchmark model", "$MODEL_ASSET (${modelBytes.size} bytes)", ReportLevel.GOOD)

        timeVariant(section, "cpu", modelBytes) { it.numThreads = 2 }

        if (gpuDelegateSupported()) {
            timeVariant(section, "gpu", modelBytes) {
                it.addDelegate(GpuDelegate(CompatibilityList().bestOptionsForThisDevice))
            }
        } else {
            section += ReportEntry("gpu inference", "skipped, GPU delegate unsupported", ReportLevel.WARN)
        }

        section += ReportEntry("recommended backend", recommendedBackend(section), ReportLevel.NOTE)
        return section
    }

    private fun timeVariant(
        section: ReportSection,
        label: String,
        modelBytes: ByteArray,
        configure: (Interpreter.Options) -> Unit
    ) {
        val loadStart = System.nanoTime()
        var interpreter: Interpreter? = null
        try {
            val options = Interpreter.Options().apply { configure(this) }
            interpreter = Interpreter(modelBytes, options)
            val loadMs = ReportFormat.duration(System.nanoTime() - loadStart)

            val input = interpreter.getInputTensor(0)
            val output = interpreter.getOutputTensor(0)
            if (input == null || output == null) {
                section += ReportEntry("$label inference", "model exposes no tensor 0", ReportLevel.FAIL)
                return
            }

            section += ReportEntry("$label tensors",
                "in ${input.shape().joinToString("x")} ${input.dataType()}, " +
                    "out ${output.shape().joinToString("x")} ${output.dataType()}", ReportLevel.NOTE)

            val inputBuffer = ByteBuffer.allocateDirect(input.numBytes())
            val outputBuffer = ByteBuffer.allocateDirect(output.numBytes())
            AppLog.note("litert $label: shapes in=${input.shape().joinToString("x")} out=${output.shape().joinToString("x")}")

            val samples = ArrayList<Double>(ITERATIONS)
            var failure: Throwable? = null
            for (iteration in 0 until ITERATIONS) {
                try {
                    val start = System.nanoTime()
                    interpreter.run(inputBuffer, outputBuffer)
                    val elapsed = ReportFormat.duration(System.nanoTime() - start)
                    samples += elapsed
                    AppLog.inference(MODEL_ASSET, label, iteration + 1, elapsed)
                } catch (error: Throwable) {
                    failure = error
                    break
                }
            }

            if (failure != null) {
                section += ReportEntry("$label inference", "failed: ${failure?.message}", ReportLevel.FAIL)
            } else {
                val sorted = samples.sorted()
                val median = sorted[sorted.size / 2]
                section += ReportEntry("$label inference",
                    "${ReportFormat.number(median)} ms median of ${samples.size} " +
                        "(load ${ReportFormat.number(loadMs)} ms)",
                    if (median < 10) ReportLevel.GOOD else ReportLevel.WARN)
                section += ReportEntry("  min / max",
                    "${ReportFormat.number(sorted.first())} / ${ReportFormat.number(sorted.last())} ms",
                    ReportLevel.NOTE)
            }
        } catch (error: Throwable) {
            AppLog.fail("LiteRT $label benchmark failed", error)
            section += ReportEntry("$label inference",
                "failed after ${ReportFormat.number(ReportFormat.duration(System.nanoTime() - loadStart))} ms: " +
                    error.message, ReportLevel.FAIL)
        } finally {
            interpreter?.close()
        }
    }

    private fun recommendedBackend(section: ReportSection): String {
        val timed = section.entries
            .filter { it.label.endsWith(" inference") }
            .mapNotNull { entry ->
                val value = entry.value.substringBefore(" ").toDoubleOrNull()
                if (value == null) null else entry.label.removeSuffix(" inference") to value
            }
        if (timed.isEmpty()) return "no successful inference; see failures above"
        val best = timed.minByOrNull { it.second } ?: return "unavailable"
        return "${best.first} at ${ReportFormat.number(best.second)} ms"
    }
}
