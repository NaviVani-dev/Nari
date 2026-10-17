package org.navivani.musicservice

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale

object Discovery {

    private data class Entry(val id: String, val name: String, val mimeType: String, val size: Long, val modified: Long)

    fun run(context: Context, request: String): String {
        val query = JSONObject(request)
        val ignored = folders(query.optJSONArray("ignored"))
        val lost = JSONArray()
        val granted = context.contentResolver.persistedUriPermissions
            .filter { it.isReadPermission }
            .map { it.uri.toString() }
            .toSet()
        val result = LinkedHashMap<String, JSONObject>()
        folders(query.optJSONArray("music")).forEach { folder ->
            if (folder.optString("uri") !in granted) {
                Log.w(TAG, "Lost access to ${folder.optString("uri")}")
                lost.put(folder.optString("uri"))
                return@forEach
            }
            val uri = Uri.parse(folder.optString("uri"))
            val documentId = folder.optString("document_id").ifEmpty { treeId(uri) }
            val name = folder.optString("name").ifEmpty { documentId }
            scan(context, uri, documentId, name, ignored.map { it.optString("document_id") }, result)
        }
        return JSONObject().put("files", JSONArray(result.values.toList())).put("lost", lost).toString()
    }

    private fun folders(array: JSONArray?): List<JSONObject> =
        (0 until (array?.length() ?: 0)).mapNotNull { array?.optJSONObject(it) }

    private fun treeId(uri: Uri): String = try {
        DocumentsContract.getTreeDocumentId(uri)
    } catch (_: Exception) {
        uri.toString()
    }

    private fun scan(
        context: Context,
        tree: Uri,
        documentId: String,
        path: String,
        ignored: List<String>,
        result: MutableMap<String, JSONObject>
    ) {
        if (ignored.any { documentId == it || documentId.startsWith("$it/") }) return
        val children = mutableListOf<Entry>()
        try {
            context.contentResolver.query(
                DocumentsContract.buildChildDocumentsUriUsingTree(tree, documentId), DOCUMENT_PROJECTION, null, null, null
            )?.use { cursor ->
                while (cursor.moveToNext()) {
                    children += Entry(
                        cursor.getString(0),
                        cursor.getString(1) ?: "",
                        cursor.getString(2) ?: "application/octet-stream",
                        cursor.getLong(3),
                        cursor.getLong(4)
                    )
                }
            }
        } catch (error: Exception) {
            Log.w(TAG, "Could not list $documentId", error)
            return
        }
        if (children.any { it.name == ".nomedia" }) return
        val cover = children
            .filter { it.mimeType.startsWith("image/", true) }
            .maxByOrNull { coverScore(it.name, it.mimeType, path) }
            ?.takeIf { coverScore(it.name, it.mimeType, path) > 0 }
            ?.let { DocumentsContract.buildDocumentUriUsingTree(tree, it.id).toString() }
            ?: ""
        val lyricFiles = children.filter {
            it.mimeType != DocumentsContract.Document.MIME_TYPE_DIR &&
                extension(it.name) in LYRIC_EXTENSIONS &&
                it.size <= MAX_LYRICS_SIZE
        }
        children.forEach { child ->
            if (child.name.startsWith(".")) return@forEach
            val childPath = "$path/${child.name}"
            if (child.mimeType == DocumentsContract.Document.MIME_TYPE_DIR) {
                scan(context, tree, child.id, childPath, ignored, result)
            } else if (child.mimeType.startsWith("audio/", true) || extension(child.name) in AUDIO_EXTENSIONS) {
                val uri = DocumentsContract.buildDocumentUriUsingTree(tree, child.id).toString()
                val base = child.name.substringBeforeLast('.').lowercase(Locale.ROOT)
                val lyrics = lyricFiles
                    .filter { it.name.substringBeforeLast('.').lowercase(Locale.ROOT) == base }
                    .maxByOrNull { LYRIC_EXTENSIONS.size - LYRIC_EXTENSIONS.indexOf(extension(it.name)) }
                    ?.let { DocumentsContract.buildDocumentUriUsingTree(tree, it.id).toString() }
                    ?: ""
                result[uri] = source(uri, child.name, childPath, child.mimeType, child.size, child.modified, 0L, "", cover, lyrics)
            }
        }
    }

    private fun source(
        uri: String,
        name: String,
        path: String,
        mime: String,
        size: Long,
        modified: Long,
        added: Long,
        mediaId: String,
        cover: String,
        lyrics: String
    ) = JSONObject()
        .put("uri", uri)
        .put("name", name)
        .put("path", path)
        .put("mime", mime)
        .put("size", size)
        .put("modified", modified)
        .put("added", added)
        .put("media_id", mediaId)
        .put("cover", cover)
        .put("lyrics", lyrics)

    private fun extension(name: String) = name.substringAfterLast('.', "").lowercase(Locale.ROOT)

    private fun coverScore(name: String, mimeType: String, path: String): Int {
        val base = name.substringBeforeLast('.').lowercase(Locale.ROOT)
        val folderName = path.substringAfterLast('/').lowercase(Locale.ROOT)
        var score = listOf("front", "art", "album", "folder", "cover", folderName)
            .mapIndexed { index, value -> if (value.isNotEmpty() && base.contains(value)) index + 1 else 0 }
            .sum()
        score *= when {
            mimeType.equals("image/webp", true) -> 5
            mimeType.equals("image/jpeg", true) || mimeType.equals("image/jpg", true) -> 4
            mimeType.equals("image/png", true) -> 3
            else -> 1
        }
        score *= if (extension(name) in setOf("webp", "jpg", "jpeg", "png")) 2 else 1
        return score
    }

    private const val TAG = "NariDiscovery"
    private const val MAX_LYRICS_SIZE = 2L * 1024L * 1024L
    private val AUDIO_EXTENSIONS = setOf("mp3", "m4a", "mp4", "aac", "flac", "ogg", "oga", "opus", "wav", "wave", "aif", "aiff", "wma",
        "mid", "midi", "kar", "sid", "mod", "xm", "s3m", "it", "mptm", "669", "amf", "ams", "dbm", "dmf", "dsm", "far", "mdl", "med", "mo3", "mt2",
        "mtm", "okt", "psm", "ptm", "stm", "ult", "umx")
    private val LYRIC_EXTENSIONS = listOf("ttml", "lrc", "txt")
    private val DOCUMENT_PROJECTION = arrayOf(
        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        DocumentsContract.Document.COLUMN_MIME_TYPE,
        DocumentsContract.Document.COLUMN_SIZE,
        DocumentsContract.Document.COLUMN_LAST_MODIFIED
    )
}
