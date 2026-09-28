package com.example.lumaframe.support

import android.util.Log

/**
 * Single logging entry point.
 *
 * Every call goes to logcat *and* to a bounded in-memory ring buffer, so the
 * capability report can include recent lines on a device with no debugger attached.
 *
 * Never log image contents, file names, or user identifiers.
 */
object AppLog {

    const val TAG = "LumaFrame"
    const val BUFFER_CAPACITY = 600

    private val buffer = ArrayDeque<String>()

    fun note(message: String) = write(Log.INFO, message, null)

    fun warn(message: String) = write(Log.WARN, "! $message", null)

    fun fail(message: String, error: Throwable? = null) = write(Log.ERROR, "x $message", error)

    /** The brief requires a log line on every model load and every 30th inference. */
    fun inference(model: String, backend: String, index: Int, milliseconds: Double) {
        val line = "ml #$index $model backend=$backend ${String.format(java.util.Locale.ROOT, "%.2f", milliseconds)}ms"
        if (index == 1 || index % 30 == 0) {
            write(Log.INFO, line, null)
        } else {
            Log.d(TAG, line)
        }
    }

    private fun write(priority: Int, message: String, error: Throwable?) {
        synchronized(buffer) {
            buffer.addLast(message)
            while (buffer.size > BUFFER_CAPACITY) {
                buffer.removeFirst()
            }
        }
        if (error != null) {
            Log.println(priority, TAG, "$message | ${error.javaClass.simpleName}: ${error.message}")
        } else {
            Log.println(priority, TAG, message)
        }
    }

    fun recentLines(limit: Int? = null): List<String> = synchronized(buffer) {
        val all = buffer.toList()
        if (limit == null || limit >= all.size) all else all.takeLast(limit)
    }

    fun clear() {
        synchronized(buffer) { buffer.clear() }
    }
}
