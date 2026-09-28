package com.example.lumaframe.diagnostics

import android.content.Context
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.util.Range
import android.util.Size
import com.example.lumaframe.support.AppLog

/**
 * Enumerates every camera through Camera2 and reports what the app can actually ask
 * for.
 *
 * This is deliberately *not* filtered to cameras a third-party app may use. The S21
 * Ultra lists four back cameras, but physical camera access and RAW are separate
 * capabilities, so the report states them separately and the UI follows the report.
 * See docs/ARCHITECTURE.md section 5.
 */
object CameraProbe {

    fun sections(context: Context): List<ReportSection> {
        val manager = context.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
            ?: return listOf(ReportSection("Camera2").apply {
                add(ReportEntry("result", "CameraManager unavailable", ReportLevel.FAIL))
            })

        val ids = try {
            manager.cameraIdList.toList()
        } catch (error: Throwable) {
            return listOf(ReportSection("Camera2").apply {
                add(ReportEntry("cameraIdList", "failed: ${error.message}", ReportLevel.FAIL))
                add(ReportEntry("note", "a SecurityException here means CAMERA permission is not granted",
                    ReportLevel.WARN))
            })
        }

        AppLog.note("camera2: ${ids.size} camera ids: $ids")

        val sections = mutableListOf(overviewSection(manager, ids))
        for (id in ids) {
            sections += cameraSection(manager, id)
        }
        return sections
    }

    // MARK: - Overview

    private fun overviewSection(manager: CameraManager, ids: List<String>): ReportSection {
        val section = ReportSection("Camera2 overview")
        var back = 0
        var front = 0
        var external = 0
        for (id in ids) {
            when (facingName(safeFacing(manager, id))) {
                "back" -> back++
                "front" -> front++
                "external" -> external++
            }
        }
        section += listOf(
            ReportEntry("camera ids", if (ids.isEmpty()) "none" else ids.joinToString(", "),
                if (ids.isEmpty()) ReportLevel.FAIL else ReportLevel.GOOD),
            ReportEntry("camera count", ids.size),
            ReportEntry("back camera count", back, if (back == 0) ReportLevel.FAIL else ReportLevel.GOOD),
            ReportEntry("front camera count", front),
            ReportEntry("external camera count", external),
            ReportEntry("lens switching UI needed", back > 1,
                if (back > 1) ReportLevel.GOOD else ReportLevel.NOTE)
        )
        return section
    }

    private fun safeFacing(manager: CameraManager, id: String): Int? = try {
        manager.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING)
    } catch (error: Throwable) {
        null
    }

    // MARK: - Per camera

    private fun cameraSection(manager: CameraManager, id: String): ReportSection {
        val section = ReportSection("Camera2 [$id]")

        val characteristics = try {
            manager.getCameraCharacteristics(id)
        } catch (error: Throwable) {
            section += ReportEntry("result", "characteristics failed: ${error.message}", ReportLevel.FAIL)
            return section
        }

        val info = Info(characteristics)

        section += listOf(
            ReportEntry("lens facing", facingName(info.lensFacing)),
            ReportEntry("hardware level", hardwareLevelName(info.hardwareLevel)),
            ReportEntry("focal lengths",
                ReportFormat.list(info.focalLengths.map { "${ReportFormat.number(it.toDouble(), 2)} mm" })),
            ReportEntry("equivalent focal lengths",
                ReportFormat.list(info.focalLengths.map { focalTo35mm(it, info.physicalSize).toString() }),
                ReportLevel.NOTE),
            ReportEntry("physical camera ids",
                ReportFormat.list(physicalIds(characteristics), "none"), ReportLevel.NOTE),
            ReportEntry("is logical multi camera",
                info.capabilities.contains(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_LOGICAL_MULTI_CAMERA),
                ReportLevel.NOTE)
        )

        section += capabilitiesEntries(info)
        section += sensorEntries(info)
        section += controlEntries(info)
        section += outputEntries(info)
        return section
    }

    // MARK: - Groups

    private fun capabilitiesEntries(info: Info): List<ReportEntry> {
        val capabilities = info.capabilities
        fun supported(key: Int) = capabilities.contains(key)

        // Camera2 has no MANUAL_SENSOR_BLOCKED and no RAW_SENSOR. The real names are
        // REQUEST_AVAILABLE_CAPABILITIES_MANUAL_POST_PROCESSING and
        // REQUEST_AVAILABLE_CAPABILITIES_RAW, so a device that advertises neither
        // reports the absence rather than failing to compile.
        val manualSensor = supported(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR)
        val manualPostProcessing =
            supported(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_POST_PROCESSING)

        return listOf(
            ReportEntry("MANUAL_SENSOR", manualSensor,
                if (manualSensor) ReportLevel.GOOD else ReportLevel.FAIL),
            ReportEntry("MANUAL_POST_PROCESSING", manualPostProcessing,
                if (manualPostProcessing) ReportLevel.GOOD else ReportLevel.INFO),
            ReportEntry("RAW", supported(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_RAW),
                if (supported(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_RAW))
                    ReportLevel.GOOD else ReportLevel.FAIL),
            ReportEntry("LOGICAL_MULTI_CAMERA",
                supported(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_LOGICAL_MULTI_CAMERA), ReportLevel.NOTE),
            ReportEntry("per frame HDR (DYNAMIC_RANGE_TEN_BIT)",
                info.dynamicRangeTenBit, if (info.dynamicRangeTenBit) ReportLevel.GOOD else ReportLevel.INFO),
            ReportEntry("manual post processing",
                supported(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_POST_PROCESSING), ReportLevel.NOTE),
            ReportEntry("all capabilities",
                ReportFormat.list(capabilities.map(::capabilityName)), ReportLevel.NOTE)
        )
    }

    private fun sensorEntries(info: Info): List<ReportEntry> {
        val size = info.physicalSize
        val pixelArray = info.pixelArraySize
        val megapixels = if (size != null && pixelArray != null && size.width > 0 && size.height > 0) {
            val effective = (minOf(size.width, pixelArray.width).toDouble() *
                minOf(size.height, pixelArray.height))
            ReportFormat.number(effective / 1_000_000.0, 1) + " MP effective"
        } else "unknown"

        return listOf(
            ReportEntry("sensor physical size",
                size?.let { "${ReportFormat.number(it.width.toDouble() / 1000.0, 2)} x " +
                    "${ReportFormat.number(it.height.toDouble() / 1000.0, 2)} mm" } ?: "unknown"),
            ReportEntry("pixel array size",
                pixelArray?.let { "${it.width} x ${it.height}" } ?: "unknown"),
            ReportEntry("effective resolution", megapixels, ReportLevel.NOTE),
            ReportEntry("iso range",
                info.sensitivityRange?.let { ReportFormat.range(it.lower.toDouble(), it.upper.toDouble()) }
                    ?: "unknown",
                if (info.sensitivityRange != null) ReportLevel.GOOD else ReportLevel.FAIL),
            ReportEntry("max analog sensitivity",
                info.maxAnalogSensitivity?.toString() ?: "unknown"),
            ReportEntry("exposure time range",
                info.exposureTimeRange?.let {
                    "${nanos(it.lower)} ... ${nanos(it.upper)}"
                } ?: "unknown",
                if (info.exposureTimeRange != null) ReportLevel.GOOD else ReportLevel.FAIL),
            ReportEntry("exposure time range (seconds)",
                info.exposureTimeRange?.let {
                    "${ReportFormat.number(it.lower / 1_000_000_000.0, 6)} ... " +
                        ReportFormat.number(it.upper / 1_000_000_000.0, 6)
                } ?: "unknown", ReportLevel.NOTE),
            ReportEntry("white balance gain range",
                info.awbGainRange?.let { ReportFormat.range(it.lower.toDouble(), it.upper.toDouble()) }
                    ?: "unknown"),
            ReportEntry("timestamp source", timestampSourceName(info.timestampSource), ReportLevel.NOTE)
        )
    }

    private fun controlEntries(info: Info): List<ReportEntry> = listOf(
        ReportEntry("AF modes", ReportFormat.list(info.afModes.map(::afModeName))),
        ReportEntry("AE modes", ReportFormat.list(info.aeModes.map(::aeModeName))),
        ReportEntry("AWB modes", ReportFormat.list(info.awbModes.map(::awbModeName))),
        // Camera2 reports AE_TARGET_FPS_RANGE as a Range<Int>, and ReportFormat.number
        // takes a Double, so both bounds are widened explicitly.
        ReportEntry("AE target fps ranges",
            ReportFormat.list(info.aeTargetFpsRanges.map {
                "${ReportFormat.number(it.lower.toDouble(), 0)}-${ReportFormat.number(it.upper.toDouble(), 0)}"
            })),
        ReportEntry("AE available target EV range",
            info.aeCompensationRange?.let { ReportFormat.range(it.lower.toDouble(), it.upper.toDouble()) }
                ?: "unknown", ReportLevel.NOTE),
        ReportEntry("minimum focus distance (diopters)",
            info.minimumFocusDistance?.let { ReportFormat.number(it.toDouble(), 2) } ?: "unknown"),
        ReportEntry("minimum focus distance (mm)",
            info.minimumFocusDistanceMm?.toString() ?: "unavailable (API 30+)", ReportLevel.NOTE),
        ReportEntry("optical stabilization",
            ReportFormat.list(info.opticalStabilization.map(::stabilizationName))),
        ReportEntry("flash available", info.flashAvailable, if (info.flashAvailable) ReportLevel.GOOD else ReportLevel.INFO)
    )

    private fun outputEntries(info: Info): List<ReportEntry> {
        val map = info.streamConfigurationMap
        val jpegSizes = map?.getOutputSizes(ImageFormat.JPEG).orEmpty().sortedByDescending { it.area() }
        val rawSizes = map?.getOutputSizes(ImageFormat.RAW_SENSOR).orEmpty().sortedByDescending { it.area() }
        val depthSizes = map?.getOutputSizes(ImageFormat.DEPTH16).orEmpty().sortedByDescending { it.area() }

        val ultraHdr = try {
            if (android.os.Build.VERSION.SDK_INT >= 33) {
                map?.isOutputSupportedFor(ImageFormat.JPEG_R)
            } else {
                false
            }
        } catch (error: Throwable) {
            false
        }

        return listOf(
            ReportEntry("stream configuration map", map != null,
                if (map != null) ReportLevel.GOOD else ReportLevel.FAIL),
            ReportEntry("max JPEG size",
                jpegSizes.firstOrNull()?.let { "${it.width} x ${it.height}" } ?: "unknown"),
            ReportEntry("JPEG output sizes", sizeList(jpegSizes)),
            ReportEntry("RAW_SENSOR output sizes", sizeList(rawSizes),
                if (rawSizes.isEmpty()) ReportLevel.FAIL else ReportLevel.GOOD),
            ReportEntry("DEPTH16 output sizes", sizeList(depthSizes), ReportLevel.NOTE),
            ReportEntry("ultra HDR JPEG_R supported", ultraHdr,
                if (ultraHdr) ReportLevel.GOOD else ReportLevel.INFO),
            ReportEntry("ultra HDR note",
                "JPEG_R support is the signal CameraX uses for ultra HDR. Step 1 must confirm it " +
                    "with a real capture before showing the badge, because the characteristic is " +
                    "inferred from stream support rather than declared.", ReportLevel.NOTE)
        )
    }

    // MARK: - Characteristic bundle

    private class Info(characteristics: CameraCharacteristics) {
        val lensFacing: Int? = characteristics.get(CameraCharacteristics.LENS_FACING)
        val hardwareLevel: Int? = characteristics.get(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL)
        val focalLengths: FloatArray = characteristics.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
            ?: FloatArray(0)
        val capabilities: IntArray =
            characteristics.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES) ?: IntArray(0)
        val dynamicRangeTenBit: Boolean =
            capabilities.contains(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_DYNAMIC_RANGE_TEN_BIT)
        val physicalSize: Size? = characteristics.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
        val pixelArraySize: Size? = characteristics.get(CameraCharacteristics.SENSOR_INFO_PIXEL_ARRAY_SIZE)
        val sensitivityRange: Range<Int>? = characteristics.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE)
        val maxAnalogSensitivity: Int? =
            characteristics.get(CameraCharacteristics.SENSOR_INFO_MAX_ANALOG_SENSITIVITY)
        val exposureTimeRange: Range<Long>? =
            characteristics.get(CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE)
        val awbGainRange: Range<Int>? = characteristics.get(CameraCharacteristics.CONTROL_AWB_GAINS_RANGE)
        val afModes: IntArray = characteristics.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES) ?: IntArray(0)
        val aeModes: IntArray = characteristics.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_MODES) ?: IntArray(0)
        val awbModes: IntArray = characteristics.get(CameraCharacteristics.CONTROL_AWB_AVAILABLE_MODES) ?: IntArray(0)
        val aeTargetFpsRanges: Array<Range<Int>> =
            characteristics.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
                ?: emptyArray<Range<Int>>()
        val aeCompensationRange: Range<Int>? =
            characteristics.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE)
        val minimumFocusDistance: Float? =
            characteristics.get(CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE)
        val minimumFocusDistanceMm: Float? = try {
            if (android.os.Build.VERSION.SDK_INT >= 30) {
                characteristics.get(CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE_MM)
            } else {
                null
            }
        } catch (error: Throwable) {
            null
        }
        val opticalStabilization: IntArray =
            characteristics.get(CameraCharacteristics.LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION) ?: IntArray(0)
        val flashAvailable: Boolean = characteristics.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) ?: false
        val streamConfigurationMap: android.hardware.camera2.params.StreamConfigurationMap? =
            characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val timestampSource: Int? =
            characteristics.get(CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE)
    }

    private fun physicalIds(characteristics: CameraCharacteristics): List<String> = try {
        val ids = mutableListOf<String>()
        ids += characteristics.physicalCameraIds.toList()
        if (ids.isEmpty()) {
            characteristics.get(CameraCharacteristics.LOGICAL_MULTI_CAMERA_PHYSICAL_IDS)?.toList()?.let { ids += it }
        }
        ids
    } catch (error: Throwable) {
        emptyList()
    }

    // MARK: - Naming

    private fun facingName(value: Int?): String = when (value) {
        CameraCharacteristics.LENS_FACING_FRONT -> "front"
        CameraCharacteristics.LENS_FACING_BACK -> "back"
        CameraCharacteristics.LENS_FACING_EXTERNAL -> "external"
        else -> "unknown"
    }

    private fun hardwareLevelName(value: Int?): String = when (value) {
        CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LEGACY -> "LEGACY"
        CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LIMITED -> "LIMITED"
        CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_FULL -> "FULL"
        CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_3 -> "LEVEL_3"
        CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_EXTERNAL -> "EXTERNAL"
        else -> "unknown"
    }

    private fun capabilityName(value: Int): String = when (value) {
        CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_BACKWARD_COMPATIBLE -> "BACKWARD_COMPATIBLE"
        CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR -> "MANUAL_SENSOR"
        CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR_BLOCKED -> "MANUAL_SENSOR_BLOCKED"
        CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_RAW -> "RAW"
        CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_RAW_SENSOR -> "RAW_SENSOR"
        CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_LOGICAL_MULTI_CAMERA -> "LOGICAL_MULTI_CAMERA"
        CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_STREAM_CONFIGURATION_MAP -> "STREAM_CONFIGURATION_MAP"
        CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_POST_PROCESSING -> "MANUAL_POST_PROCESSING"
        CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_DYNAMIC_RANGE_TEN_BIT -> "DYNAMIC_RANGE_TEN_BIT"
        else -> "capability$value"
    }

    private fun afModeName(value: Int): String = when (value) {
        CameraCharacteristics.CONTROL_AF_MODE_OFF -> "OFF"
        CameraCharacteristics.CONTROL_AF_MODE_AUTO -> "AUTO"
        CameraCharacteristics.CONTROL_AF_MODE_CONTINUOUS_PICTURE -> "CONTINUOUS_PICTURE"
        CameraCharacteristics.CONTROL_AF_MODE_CONTINUOUS_VIDEO -> "CONTINUOUS_VIDEO"
        CameraCharacteristics.CONTROL_AF_MODE_MACRO -> "MACRO"
        else -> "mode$value"
    }

    private fun aeModeName(value: Int): String = when (value) {
        CameraCharacteristics.CONTROL_AE_MODE_OFF -> "OFF"
        CameraCharacteristics.CONTROL_AE_MODE_ON -> "ON"
        CameraCharacteristics.CONTROL_AE_MODE_ON_ALWAYS_FLASH -> "ON_ALWAYS_FLASH"
        CameraCharacteristics.CONTROL_AE_MODE_ON_AUTO_FLASH -> "ON_AUTO_FLASH"
        CameraCharacteristics.CONTROL_AE_MODE_ON_AUTO_FLASH_REDEYE -> "ON_AUTO_FLASH_REDEYE"
        else -> "mode$value"
    }

    private fun awbModeName(value: Int): String = when (value) {
        CameraCharacteristics.CONTROL_AWB_MODE_OFF -> "OFF"
        CameraCharacteristics.CONTROL_AWB_MODE_AUTO -> "AUTO"
        CameraCharacteristics.CONTROL_AWB_MODE_INCANDESCENT -> "INCANDESCENT"
        CameraCharacteristics.CONTROL_AWB_MODE_FLUORESCENT -> "FLUORESCENT"
        CameraCharacteristics.CONTROL_AWB_MODE_DAYLIGHT -> "DAYLIGHT"
        CameraCharacteristics.CONTROL_AWB_MODE_CLOUDY_DAYLIGHT -> "CLOUDY_DAYLIGHT"
        else -> "mode$value"
    }

    private fun stabilizationName(value: Int): String = when (value) {
        CameraCharacteristics.LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION_OFF -> "OFF"
        CameraCharacteristics.LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION_ON -> "ON"
        else -> "mode$value"
    }

    /** Rule-of-thumb 35mm equivalent: focal length / sensor width * 36. */
    private fun focalTo35mm(focalLengthMm: Float, physicalSize: Size?): Int {
        if (physicalSize == null || physicalSize.width <= 0f) return 0
        return Math.round(focalLengthMm / (physicalSize.width / 1000f) * 36f)
    }

    private fun sizeList(sizes: List<Size>): String =
        if (sizes.isEmpty()) "none" else sizes.take(12).joinToString(", ") { "${it.width}x${it.height}" }

    private fun Size.area(): Long = width.toLong() * height.toLong()

    private fun nanos(value: Long): String =
        if (value >= 1_000_000_000L) {
            ReportFormat.shutter(value / 1_000_000_000.0)
        } else {
            "${value} ns"
        }

    private fun timestampSourceName(value: Int?): String = when (value) {
        CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE_UNKNOWN -> "UNKNOWN"
        CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME -> "REALTIME"
        CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE_SENSOR -> "SENSOR"
        null -> "unknown"
        else -> "source$value"
    }
}
