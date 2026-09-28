package com.example.lumaframe.diagnostics

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.launch
import java.io.File

/**
 * State for the diagnostic screen. It knows nothing about the camera, AVFoundation
 * equivalents, or the ML layer beyond forwarding to [CapabilityCollector].
 */
class ReportViewModel(
    private val appContext: Context,
    private val logLimit: Int? = null
) : ViewModel() {

    enum class State { IDLE, RUNNING, READY, FAILED }

    var state by mutableStateOf(State.IDLE)
        private set

    var report by mutableStateOf<CapabilityReport?>(null)
        private set

    var logLines by mutableStateOf<List<String>>(emptyList())
        private set

    var errorMessage by mutableStateOf<String?>(null)
        private set

    var savedFile by mutableStateOf<File?>(null)
        private set

    var shareUri by mutableStateOf<Uri?>(null)
        private set

    var includeLog by mutableStateOf(true)

    val canRun: Boolean get() = state != State.RUNNING
    val isShareable: Boolean get() = report != null

    val text: String
        get() = report?.let { ReportText.render(it, if (includeLog) logLines else emptyList()) } ?: ""

    val summary: String
        get() = report?.summary ?: "Not measured yet. Run the report."

    fun run() {
        if (!canRun) return
        state = State.RUNNING
        errorMessage = null
        savedFile = null
        shareUri = null
        viewModelScope.launch {
            try {
                val outcome = CapabilityCollector.collect(appContext, logLimit)
                report = outcome.report
                logLines = outcome.logLines
                state = State.READY
            } catch (error: Throwable) {
                errorMessage = error.message ?: error.javaClass.simpleName
                state = State.FAILED
            }
        }
    }

    fun copyToClipboard() {
        val clipboard = appContext.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return
        clipboard.setPrimaryClip(ClipData.newPlainText("LumaFrame capability report", text))
    }

    /** Writes the report to app-scoped storage. Must be called before [shareIntent]. */
    fun save(): Boolean = try {
        val file = ReportExporter.write(appContext, text)
        savedFile = file
        shareUri = ReportExporter.uriFor(appContext, file)
        true
    } catch (error: Throwable) {
        errorMessage = "Could not save report: ${error.message}"
        state = State.FAILED
        false
    }

    /** Null until [save] has succeeded. */
    fun shareIntent(): Intent? {
        val file = savedFile ?: return null
        val uri = shareUri ?: return null
        return ReportExporter.shareIntent(uri)
    }
}
