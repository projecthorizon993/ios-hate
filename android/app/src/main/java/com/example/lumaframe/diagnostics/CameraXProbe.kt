package com.example.lumaframe.diagnostics

import android.content.Context
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.core.CameraInfo
import androidx.camera.core.CameraSelector
import androidx.camera.core.ProcessCameraProvider
import androidx.camera.extensions.ExtensionMode
import androidx.camera.extensions.ExtensionsManager
import androidx.core.content.ContextCompat
import com.example.lumaframe.support.AppLog
import com.google.common.util.concurrent.ListenableFuture
import kotlinx.coroutines.suspendCancellableCoroutine
import java.util.concurrent.Executor
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * CameraX runtime probe, including the OEM extensions API.
 *
 * Two documented constraints shape this file, both from
 * docs/ARCHITECTURE.md section 2.1:
 *
 * 1. CameraX must be 1.6 or newer. From 1 November 2026, extensions support is
 *    removed on some devices for 1.5 and earlier.
 * 2. **CameraX 1.6.0 removed ImageAnalysis support whenever an extension is enabled**,
 *    because OEM implementations do not handle it reliably. That is why Step 0
 *    reports extension availability separately from analysis availability: it decides
 *    whether the app needs the two-state session design in Step 1.
 */
object CameraXProbe {

    private val extensionModes = listOf(
        "AUTO" to ExtensionMode.AUTO,
        "HDR" to ExtensionMode.HDR,
        "NIGHT" to ExtensionMode.NIGHT,
        "BOKEH" to ExtensionMode.BOKEH,
        "FACE_RETOUCH" to ExtensionMode.FACE_RETOUCH
    )

    suspend fun sections(context: Context): List<ReportSection> {
        val executor = ContextCompat.getMainExecutor(context)
        val sections = mutableListOf<ReportSection>()

        val runtime = ReportSection("CameraX runtime")
        runtime += ReportEntry("CameraX version", cameraXVersion(), ReportLevel.GOOD)
        runtime += ReportEntry("note",
            "ImageAnalysis is not available on a session with an extension enabled on CameraX 1.6+. " +
                "That is why the app has a plain and an extended session state.",
            ReportLevel.NOTE)

        val provider = try {
            ProcessCameraProvider.getInstance(context).await(executor)
        } catch (error: Throwable) {
            AppLog.fail("CameraX provider unavailable", error)
            runtime += ReportEntry("ProcessCameraProvider", "failed: ${error.message}", ReportLevel.FAIL)
            sections += runtime
            return sections
        }

        val cameraInfos = provider.availableCameraInfos
        runtime += ReportEntry("available cameras", cameraInfos.size,
            if (cameraInfos.isEmpty()) ReportLevel.FAIL else ReportLevel.GOOD)
        sections += runtime

        val cameraSection = ReportSection("CameraX cameras")
        val ids = mutableListOf<Pair<CameraInfo, String>>()
        for (info in cameraInfos) {
            val entry = try {
                val camera2 = Camera2CameraInfo.from(info)
                ids += info to camera2.cameraId
                ReportEntry(
                    "camera ${camera2.cameraId}",
                    "lens ${lensFacingName(camera2.lensFacing)}, flash ${info.hasFlashUnit()}",
                    ReportLevel.NOTE
                )
            } catch (error: Throwable) {
                ReportEntry("camera (unknown id)", "not a camera2 device: ${error.message}", ReportLevel.WARN)
            }
            cameraSection += entry
        }
        sections += cameraSection

        sections += extensionsSection(context, executor, ids)
        return sections
    }

    private suspend fun extensionsSection(
        context: Context,
        executor: Executor,
        cameras: List<Pair<CameraInfo, String>>
    ): ReportSection {
        val section = ReportSection("CameraX extensions (OEM modes)")

        val manager = try {
            ExtensionsManager.getInstanceAsync(context).await(executor)
        } catch (error: Throwable) {
            AppLog.fail("ExtensionsManager unavailable", error)
            section += ReportEntry("ExtensionsManager", "failed: ${error.message}", ReportLevel.FAIL)
            return section
        }

        section += ReportEntry("ExtensionsManager", "available", ReportLevel.GOOD)

        for ((_, id) in cameras) {
            val selector = try {
                CameraSelector.Builder()
                    .addCameraFilter { infos -> infos.filter { matchesId(it, id) } }
                    .build()
            } catch (error: Throwable) {
                section += ReportEntry("camera $id", "selector failed: ${error.message}", ReportLevel.FAIL)
                continue
            }

            for ((modeName, mode) in extensionModes) {
                val available = try {
                    manager.isExtensionAvailable(selector, mode)
                } catch (error: Throwable) {
                    section += ReportEntry("$modeName on $id", "failed: ${error.message}", ReportLevel.FAIL)
                    continue
                }
                section += ReportEntry(
                    "$modeName on $id",
                    if (available) "available" else "unavailable",
                    if (available) ReportLevel.GOOD else ReportLevel.INFO
                )
            }
        }

        section += ReportEntry("note",
            "An available extension forces the extended session state, where live preview ML is " +
                "paused. See docs/ARCHITECTURE.md 2.1.", ReportLevel.NOTE)
        return section
    }

    private fun matchesId(info: CameraInfo, id: String): Boolean = try {
        Camera2CameraInfo.from(info).cameraId == id
    } catch (error: Throwable) {
        false
    }

    /**
     * `CameraX.VERSION` is not a public constant in every 1.x release, so it is read
     * reflectively. A failure here is reported rather than assumed.
     */
    private fun cameraXVersion(): String = try {
        Class.forName("androidx.camera.core.CameraX").getField("VERSION").get(null) as? String
            ?: "VERSION field is not a String"
    } catch (error: Throwable) {
        "not exposed publicly; see gradle/libs.versions.toml for the pinned version"
    }

    private fun lensFacingName(value: Int?): String = when (value) {
        CameraSelector.LENS_FACING_FRONT -> "front"
        CameraSelector.LENS_FACING_BACK -> "back"
        null -> "unknown"
        else -> "value$value"
    }
}

/** Bridges a CameraX `ListenableFuture` to a coroutine, cancelling it if the caller goes away. */
internal suspend fun <T> ListenableFuture<T>.await(executor: Executor): T =
    suspendCancellableCoroutine { continuation ->
        addListener({
            try {
                continuation.resume(get())
            } catch (error: Throwable) {
                continuation.resumeWithException(error)
            }
        }, executor)
        continuation.invokeOnCancellation { cancel(false) }
    }
