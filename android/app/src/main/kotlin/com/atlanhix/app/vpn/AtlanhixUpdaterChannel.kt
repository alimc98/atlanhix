package com.atlanhix.app.vpn

import android.app.Activity
import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import androidx.core.content.FileProvider
import org.json.JSONObject
import java.io.File

/**
 * v0.6.0 §in-app-update — the user asked for the WHOLE update to live inside
 * the app: "وقتی دانلود رو میزنیم همونجا دانلود کنه توی خود برنامه و بعد
 * اتوماتیک نصبش کنه — اصلا فازِ رفتن توی مرورگر و دانلود دستی گیت‌هاب نباشه."
 *
 * Channel: `dev.atlanhix/updater`
 *   download  {url, version} → {ok, downloadId?}
 *   status    {downloadId}   → {ok, status: pending|running|done|failed, progress?}
 *   install   {version}      → {ok}  (launches ACTION_INSTALL_PACKAGE)
 *
 * Flow: [download] hands the APK URL to Android's own DownloadManager (it
 * streams in the background, survives app switches, and notifies us via a
 * broadcast). When the download completes, [install] exposes the file
 * through a FileProvider and fires ACTION_INSTALL_PACKAGE — Android then
 * shows its standard one-tap "install this update" consent (there is no
 * silent-install API for sideloaded APKs; this is the closest honest
 * automatic path). The old flow opened a BROWSER on the GitHub release page
 * — exactly the manual step the user wanted gone.
 */
class AtlanhixUpdaterChannel(private val activity: Activity) {

    companion object {
        const val CHANNEL = "dev.atlanhix/updater"
        private const val UPDATES_DIR = "updates"
        private const val AUTHORITY = "com.atlanhix.app.fileprovider"
        private const val APK_MIME = "application/vnd.android.package-archive"
    }

    fun handle(method: String, arg: JSONObject?): JSONObject = when (method) {
        "download" -> download(arg ?: JSONObject())
        "status" -> status(arg ?: JSONObject())
        "install" -> install(arg ?: JSONObject())
        // v0.6.3 §update-fix: the progress dialog's Cancel.
        "cancel" -> cancel(arg ?: JSONObject())
        else -> JSONObject().put("error", "unknown method: $method")
    }

    private fun safeVersion(version: String): String =
        version.replace(Regex("[^A-Za-z0-9._-]"), "_")

    /**
     * v0.6.3 §update-fix: the APK lives in the app's EXTERNAL files dir
     * (`Android/data/<pkg>/files/Download/`), NOT in the internal filesDir.
     *
     * ROOT CAUSE of "آپدیت درون‌برنامه‌ای هنوز کار نمی‌کند": the download
     * request pointed DownloadManager at an internal-storage path through
     * `setDestinationUri(Uri.fromFile(...))`. DownloadManager runs in its own
     * process and, since API 29, cannot open an arbitrary app-private data
     * path — the enqueue either threw immediately or the download died as
     * STATUS_FAILED (error file/unknown) while the dialog sat on 0%.
     * `setDestinationInExternalFilesDir` is the supported contract: the
     * system owns the path, the app can read the finished file, and the
     * FileProvider exposes exactly this directory (see external-files-path
     * in res/xml/file_paths.xml).
     */
    private fun updatesDir(): File {
        val ext = activity.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
        if (ext != null) {
            ext.mkdirs()
            return ext
        }
        // Very old/odd devices without external storage — the file then
        // cannot be shared with the installer anyway; keep the legacy path
        // so the failure is at least visible in the status dialog.
        return File(activity.filesDir, UPDATES_DIR).apply { mkdirs() }
    }

    private fun apkFile(version: String): File =
        File(updatesDir(), "atlanhix-${safeVersion(version)}.apk")

    private fun download(arg: JSONObject): JSONObject {
        val url = arg.optString("url").orEmpty()
        if (url.isEmpty()) return JSONObject().put("ok", false).put("error", "no url")
        val version = arg.optString("version", "update")
        val dest = apkFile(version)
        // Fresh file — a stale previous download must never be installed.
        dest.delete()
        return try {
            val req = DownloadManager.Request(Uri.parse(url))
                .setTitle("Atlanhix $version")
                .setDescription("Downloading the Atlanhix update")
                .setNotificationVisibility(
                    DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
                // v0.6.3 §update-fix: the SUPPORTED destination contract —
                // internal filesDir is not writable by DownloadManager (see
                // updatesDir()).
                .setDestinationInExternalFilesDir(
                    activity, Environment.DIRECTORY_DOWNLOADS, dest.name)
                .setAllowedOverMetered(true)
                .setAllowedOverRoaming(true)
            val id = downloadManager().enqueue(req)
            JSONObject().put("ok", true).put("downloadId", id).put("path", dest.absolutePath)
        } catch (e: Exception) {
            JSONObject().put("ok", false).put("error", "${e.message}")
        }
    }

    private fun status(arg: JSONObject): JSONObject {
        val id = arg.optLong("downloadId", -1)
        if (id < 0) return JSONObject().put("ok", false).put("error", "no downloadId")
        return try {
            val q = DownloadManager.Query().setFilterById(id)
            val c = downloadManager().query(q)
            c.use { cursor ->
                if (!cursor.moveToFirst()) {
                    return JSONObject().put("ok", true).put("status", "gone")
                }
                val state = cursor.getInt(
                    cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
                val bytes = cursor.getLong(cursor.getColumnIndexOrThrow(
                    DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR))
                val total = cursor.getLong(cursor.getColumnIndexOrThrow(
                    DownloadManager.COLUMN_TOTAL_SIZE_BYTES))
                val reason = cursor.getInt(cursor.getColumnIndexOrThrow(
                    DownloadManager.COLUMN_REASON))
                val st = when (state) {
                    DownloadManager.STATUS_SUCCESSFUL -> "done"
                    DownloadManager.STATUS_FAILED -> "failed"
                    DownloadManager.STATUS_PAUSED -> "paused"
                    DownloadManager.STATUS_PENDING -> "pending"
                    else -> "running"
                }
                JSONObject()
                    .put("ok", true)
                    .put("status", st)
                    .put("bytes", bytes)
                    .put("total", if (total > 0) total else JSONObject.NULL)
                    .put("progress", if (total > 0) (bytes * 100 / total).toInt() else JSONObject.NULL)
                    .put("reason", if (st == "failed") reason else JSONObject.NULL)
            }
        } catch (e: Exception) {
            JSONObject().put("ok", false).put("error", "${e.message}")
        }
    }

    private fun cancel(arg: JSONObject): JSONObject {
        val id = arg.optLong("downloadId", -1)
        if (id < 0) return JSONObject().put("ok", false).put("error", "no downloadId")
        return try {
            JSONObject().put("ok", downloadManager().remove(id) > 0)
        } catch (e: Exception) {
            JSONObject().put("ok", false).put("error", "${e.message}")
        }
    }

    private fun install(arg: JSONObject): JSONObject {
        val version = arg.optString("version", "update")
        val file = apkFile(version)
        if (!file.exists() || file.length() == 0L) {
            return JSONObject().put("ok", false).put("error", "apk not downloaded")
        }
        // v0.6.3 §update-fix: since Android 8 a sideloading app needs the
        // user's one-time "install unknown apps" grant. Without this check
        // the installer intent silently bounced (or showed a settings wall)
        // and the update looked broken. Open the EXACT settings page for
        // this app; the UI then tells the user to come back and tap Install
        // again (openedSettings drives that copy).
        if (Build.VERSION.SDK_INT >= 26 &&
            !activity.packageManager.canRequestPackageInstalls()
        ) {
            return try {
                activity.startActivity(Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:${activity.packageName}")))
                JSONObject().put("ok", false)
                    .put("error", "unknown_sources")
                    .put("openedSettings", true)
            } catch (e: Exception) {
                JSONObject().put("ok", false)
                    .put("error", "unknown_sources: ${e.message}")
            }
        }
        // NOTE: the catch branch MUST return — without it the try/catch
        // expression's type is a mix of Uri and JSONObject and Kotlin fails
        // the build ("Initializer type mismatch: expected 'Uri', actual
        // 'Any!'") long before the installer ever runs.
        val uri: Uri = try {
            FileProvider.getUriForFile(activity, AUTHORITY, file)
        } catch (e: Exception) {
            return JSONObject().put("ok", false).put("error", "provider: ${e.message}")
        }
        // v0.6.3 §update-fix: ACTION_VIEW on the APK MIME is the modern,
        // supported installer trigger (ACTION_INSTALL_PACKAGE is deprecated
        // and restricted on recent targets). Keep it as the fallback for
        // devices whose package installer only advertises the legacy action.
        val view = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, APK_MIME)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            putExtra(Intent.EXTRA_NOT_UNKNOWN_SOURCE, true)
        }
        if (view.resolveActivity(activity.packageManager) != null) {
            return try {
                activity.startActivity(view)
                JSONObject().put("ok", true).put("via", "view")
            } catch (e: Exception) {
                JSONObject().put("ok", false).put("error", "${e.message}")
            }
        }
        @Suppress("DEPRECATION")
        val legacy = Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
            setDataAndType(uri, APK_MIME)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return try {
            activity.startActivity(legacy)
            JSONObject().put("ok", true).put("via", "install_package")
        } catch (e: Exception) {
            JSONObject().put("ok", false).put("error", "${e.message}")
        }
    }

    private fun downloadManager(): DownloadManager =
        activity.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
}
