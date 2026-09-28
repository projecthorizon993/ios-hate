package com.example.lumaframe.diagnostics

import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import java.io.File

/**
 * Writes the report into app-scoped storage and returns a shareable content URI.
 *
 * Both locations are app-specific, so no storage permission is required on any API
 * level. The file is also reachable from a file manager under
 * `Android/data/com.example.lumaframe/files/reports/`.
 */
object ReportExporter {

    private const val DIRECTORY = "reports"

    fun write(context: Context, text: String, now: Long = System.currentTimeMillis()): File {
        val directory = File(context.getExternalFilesDir(null) ?: context.filesDir, DIRECTORY)
        if (!directory.exists() && !directory.mkdirs()) {
            throw IllegalStateException("could not create ${directory.absolutePath}")
        }
        val name = "lumaframe-report-${ReportText.stamp(now)
            .replace(":", "")
            .replace("T", "-")}.txt"
        val file = File(directory, name)
        file.writeText(text)
        return file
    }

    fun uriFor(context: Context, file: File) =
        FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)

    fun shareIntent(uri: android.net.Uri): Intent =
        Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_STREAM, uri)
            putExtra(Intent.EXTRA_SUBJECT, "LumaFrame capability report")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
}
