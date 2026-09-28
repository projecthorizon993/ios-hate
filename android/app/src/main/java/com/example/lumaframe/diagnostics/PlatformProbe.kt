package com.example.lumaframe.diagnostics

import android.app.ActivityManager
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.hardware.display.DisplayManager
import android.os.Build
import android.provider.Settings
import android.view.Display

/**
 * Device, SoC and display identity.
 *
 * The `ro.*` reads go through reflection on `android.os.SystemProperties`, which is a
 * hidden API. On Android 15 hidden-API access may simply return null, so every read is
 * individually guarded and reported as "unavailable" rather than assumed. The public
 * `Build.SOC_MANUFACTURER` / `Build.SOC_MODEL` are preferred where they exist.
 *
 * **No feature may branch on a value produced by this file.** The SoC classification
 * exists so the ML probe knows which delegate is worth probing; see
 * docs/ARCHITECTURE.md section 2.2.
 */
object PlatformProbe {

    /** Which LiteRT delegate family, if any, is worth probing on this SoC. */
    enum class SocVendor(val label: String, val npuDelegate: String?) {
        QUALCOMM("Qualcomm", "Qualcomm AI Engine Direct"),
        MEDIATEK("MediaTek", "MediaTek NeuroPilot"),
        INTEL("Intel", "Intel OpenVINO"),
        SAMSUNG("Samsung Exynos", "Samsung Exynos AI LiteCore (not yet released)"),
        GOOGLE("Google Tensor", "Google Tensor"),
        OTHER("unknown", null)
    }

    fun sections(context: Context): List<ReportSection> = listOf(
        deviceSection(),
        socSection(),
        systemSection(context),
        displaySection(context)
    )

    fun socVendor(): SocVendor {
        val haystack = listOfNotNull(
            systemProperty("ro.soc.manufacturer"),
            Build.SOC_MANUFACTURER,
            Build.MANUFACTURER,
            Build.HARDWARE,
            systemProperty("ro.board.platform")
        ).joinToString(" ").lowercase()

        return when {
            listOf("qcom", "qualcomm", "sm8450", "sdm888", "lahaina").any(haystack::contains) ->
                SocVendor.QUALCOMM
            listOf("mediatek", "mt689").any(haystack::contains) -> SocVendor.MEDIATEK
            haystack.contains("intel") -> SocVendor.INTEL
            listOf("exynos", "s5e88", "universal2100").any(haystack::contains) -> SocVendor.SAMSUNG
            listOf("tensor", "gs101", "gs201", "zuma").any(haystack::contains) -> SocVendor.GOOGLE
            else -> SocVendor.OTHER
        }
    }

    // MARK: - Device

    private fun deviceSection(): ReportSection {
        val section = ReportSection("Device")
        section += listOf(
            ReportEntry("manufacturer", Build.MANUFACTURER),
            ReportEntry("brand", Build.BRAND),
            ReportEntry("model", Build.MODEL),
            ReportEntry("device", Build.DEVICE),
            ReportEntry("board", Build.BOARD),
            ReportEntry("hardware", Build.HARDWARE),
            ReportEntry("abis", Build.SUPPORTED_ABIS.joinToString(", ")),
            ReportEntry("fingerprint", Build.FINGERPRINT, ReportLevel.NOTE),
            ReportEntry("is physical device", isPhysicalDevice(), ReportLevel.NOTE)
        )
        return section
    }

    private fun socSection(): ReportSection {
        val section = ReportSection("SoC")
        val vendor = socVendor()
        section += listOf(
            ReportEntry("Build.SOC_MANUFACTURER", Build.SOC_MANUFACTURER ?: "unavailable (needs API 31+)"),
            ReportEntry("Build.SOC_MODEL", Build.SOC_MODEL ?: "unavailable (needs API 31+)"),
            ReportEntry("ro.soc.manufacturer", systemProperty("ro.soc.manufacturer") ?: "unavailable (hidden API)"),
            ReportEntry("ro.soc.model", systemProperty("ro.soc.model") ?: "unavailable (hidden API)"),
            ReportEntry("ro.board.platform", systemProperty("ro.board.platform") ?: "unavailable (hidden API)"),
            ReportEntry("classified vendor", vendor.label,
                if (vendor == SocVendor.OTHER) ReportLevel.WARN else ReportLevel.GOOD),
            ReportEntry("candidate NPU delegate", vendor.npuDelegate ?: "none",
                if (vendor.npuDelegate == null) ReportLevel.WARN else ReportLevel.NOTE),
            ReportEntry("note",
                "Samsung System LSI / Exynos AI LiteCore and Google Tensor were still listed as " +
                    "\"coming soon\" on the official LiteRT NPU page. See docs/ARCHITECTURE.md 2.2.",
                ReportLevel.NOTE)
        )
        return section
    }

    // MARK: - System

    private fun systemSection(context: Context): ReportSection {
        val section = ReportSection("System")
        val activityManager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        val memoryInfo = ActivityManager.MemoryInfo()
        activityManager?.getMemoryInfo(memoryInfo)
        val wideGamut = context.resources.configuration.isScreenWideColorGamut

        section += listOf(
            ReportEntry("android release", Build.VERSION.RELEASE),
            ReportEntry("sdk int", Build.VERSION.SDK_INT),
            ReportEntry("security patch", Build.VERSION.SECURITY_PATCH),
            ReportEntry("build type", Build.TYPE),
            ReportEntry("is debuggable", isDebuggable(context)),
            ReportEntry("is low ram device", activityManager?.isLowRamDevice ?: false,
                if (activityManager?.isLowRamDevice == true) ReportLevel.WARN else ReportLevel.INFO),
            ReportEntry("memory total", gibibytes(memoryInfo.totalMem)),
            ReportEntry("memory available", gibibytes(memoryInfo.availMem)),
            ReportEntry("memory threshold", mebibytes(memoryInfo.threshold)),
            ReportEntry("cores", Runtime.getRuntime().availableProcessors().toString()),
            ReportEntry("supports wide color gamut", wideGamut,
                if (wideGamut) ReportLevel.GOOD else ReportLevel.WARN),
            ReportEntry("ui mode", if ((context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
                Configuration.UI_MODE_NIGHT_YES
            ) "dark" else "light"),
            ReportEntry("animator duration scale", animatorDurationScale(context).toString())
        )
        return section
    }

    // MARK: - Display

    private fun displaySection(context: Context): ReportSection {
        val section = ReportSection("Display")
        val displayManager = context.getSystemService(Context.DISPLAY_SERVICE) as? DisplayManager
        val display = displayManager?.getDisplay(Display.DEFAULT_DISPLAY)
        val hdr = display?.hdrCapabilities

        section += listOf(
            ReportEntry("display", display?.name ?: "unavailable"),
            ReportEntry("hdr types supported",
                hdr?.let { ReportFormat.list(it.supportedHdrTypes.map(::hdrName)) } ?: "unavailable"),
            ReportEntry("wide color gamut", context.resources.configuration.isScreenWideColorGamut),
            ReportEntry("color mode", context.resources.configuration.colorMode.toString(), ReportLevel.NOTE)
        )
        return section
    }

    private fun hdrName(type: Int): String = when (type) {
        Display.HdrCapabilities.HDR_TYPE_DOLBY_VISION -> "DolbyVision"
        Display.HdrCapabilities.HDR_TYPE_HDR10 -> "HDR10"
        Display.HdrCapabilities.HDR_TYPE_HDR10_PLUS -> "HDR10+"
        Display.HdrCapabilities.HDR_TYPE_HLG -> "HLG"
        else -> "type$type"
    }

    // MARK: - CPU raster benchmark

    /**
     * Skia CPU raster benchmark. Explicit about what it measures: `Canvas` on a plain
     * `Bitmap` is CPU work, not the GPU path. The GPU number is measured in Step 1 with
     * a real GL surface. This one separates a fast SoC from a slow one for the ML tier
     * without needing a model or a GL context.
     */
    fun cpuBenchmark(iterations: Int = 20): ReportSection {
        val section = ReportSection("CPU raster benchmark (Skia, not GPU)")
        val width = 1440
        val height = 2560
        try {
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG)

            fun drawOnce() {
                paint.color = Color.rgb(30, 40, 50)
                canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), paint)
                var seed = 12345
                repeat(4000) {
                    seed = (seed * 1103515245 + 12345) and 0x7FFFFFFF
                    val x = (seed % width).toFloat()
                    seed = (seed * 1103515245 + 12345) and 0x7FFFFFFF
                    val y = (seed % height).toFloat()
                    paint.color = Color.rgb(seed and 0xFF, (seed shr 8) and 0xFF, (seed shr 16) and 0xFF)
                    canvas.drawCircle(x, y, 6f, paint)
                }
            }

            drawOnce() // warm up, do not measure the first pass

            val samples = ArrayList<Double>(iterations)
            repeat(iterations) {
                val start = System.nanoTime()
                drawOnce()
                samples.add(ReportFormat.duration(System.nanoTime() - start))
            }
            bitmap.recycle()

            val sorted = samples.sorted()
            section += listOf(
                ReportEntry("workload", "$width x $height, 4000 shapes, $iterations iterations"),
                ReportEntry("median ms", ReportFormat.number(sorted[sorted.size / 2])),
                ReportEntry("min ms", ReportFormat.number(sorted.first())),
                ReportEntry("max ms", ReportFormat.number(sorted.last()))
            )
        } catch (error: Throwable) {
            section += ReportEntry("result", "failed: ${error.message}", ReportLevel.FAIL)
        }
        return section
    }

    // MARK: - Private

    private fun gibibytes(bytes: Long): String =
        if (bytes > 0) "${ReportFormat.number(bytes.toDouble() / 1_073_741_824.0, 1)} GB" else "unavailable"

    private fun mebibytes(bytes: Long): String =
        if (bytes > 0) "${ReportFormat.number(bytes.toDouble() / 1_048_576.0, 0)} MB" else "unavailable"

    private fun animatorDurationScale(context: Context): Float = try {
        Settings.Global.getFloat(
            context.contentResolver,
            Settings.Global.ANIMATOR_DURATION_SCALE,
            1f
        )
    } catch (error: Throwable) {
        1f
    }

    private fun systemProperty(key: String): String? = try {
        val method = Class.forName("android.os.SystemProperties").getMethod("get", String::class.java)
        (method.invoke(null, key) as? String)?.takeIf { it.isNotBlank() }
    } catch (error: Throwable) {
        null
    }

    private fun isPhysicalDevice(): Boolean =
        Build.FINGERPRINT.startsWith("generic") ||
            Build.FINGERPRINT.contains("vbox") ||
            Build.FINGERPRINT.contains("emulator") ||
            Build.MODEL.contains("Emulator") ||
            Build.MODEL.contains("Android SDK built for") ||
            Build.HARDWARE.contains("goldfish") ||
            Build.HARDWARE.contains("ranchu")
}

internal fun isDebuggable(context: Context): Boolean =
    (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0

internal fun Context.hasPackage(name: String): Boolean = try {
    packageManager.getPackageInfo(name, 0)
    true
} catch (error: Throwable) {
    false
}
