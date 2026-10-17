package org.navivani.musicservice

import android.Manifest
import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.telephony.TelephonyManager
import android.view.View
import androidx.core.content.FileProvider
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.google.common.util.concurrent.ListenableFuture
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

@UnstableApi
class NariBridge(godot: Godot) : GodotPlugin(godot) {

    private val handler = Handler(Looper.getMainLooper())
    private var controller: ListenableFuture<MediaController>? = null
    private var pendingPick = ""

    private val observer = object : ContentObserver(handler) {
        override fun onChange(selfChange: Boolean) {
            handler.removeCallbacks(refresh)
            handler.postDelayed(refresh, LIBRARY_DEBOUNCE)
        }
    }

    private val refresh = Runnable { onLibraryChanged() }

    init {
        System.loadLibrary("nari")
        bridge = this
        val context = godot.context.applicationContext
        appContext = context
        migrateFolders(context)
        init(context)
        loaded = true
    }

    override fun getPluginName(): String = BuildConfig.GODOT_PLUGIN_NAME

    override fun onMainCreate(activity: Activity?): View? {
        activity?.let { appContext = it.applicationContext }
        return super.onMainCreate(activity)
    }

    override fun onGodotMainLoopStarted() {
        super.onGodotMainLoopStarted()
        val context = appContext ?: return
        context.contentResolver.registerContentObserver(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, true, observer)
        handler.post {
            if (controller == null) {
                controller = MediaController.Builder(context, SessionToken(context, ComponentName(context, NariSessionService::class.java))).buildAsync()
            }
        }
    }

    override fun onMainPause() {
        NariWebView.pause()
        super.onMainPause()
    }

    override fun onMainResume() {
        NariWebView.resume()
        val intent = activity?.intent ?: return
        intent.data?.takeIf { it.scheme == LINK_SCHEME || (intent.action == Intent.ACTION_VIEW && (it.scheme == "content" || it.scheme == "file")) }?.let {
            intent.data = null
            onLink(it.toString())
        }
        if (!intent.getBooleanExtra(EXTRA_OPEN_NOW_PLAYING, false)) return
        intent.removeExtra(EXTRA_OPEN_NOW_PLAYING)
        onNowPlaying()
    }

    override fun onMainDestroy() {
        appContext?.contentResolver?.unregisterContentObserver(observer)
        handler.removeCallbacks(refresh)
        controller?.let { MediaController.releaseFuture(it) }
        controller = null
        if (bridge === this) bridge = null
        super.onMainDestroy()
    }

    override fun onMainActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onMainActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_REQUEST) return
        val kind = pendingPick
        pendingPick = ""
        val uri = data?.data?.takeIf { resultCode == Activity.RESULT_OK }
        val context = appContext
        if (uri == null || context == null) {
            onPicked(kind, "")
            return
        }
        val value = when (kind) {
            KIND_MUSIC, KIND_IGNORED -> folder(context, uri)?.toString() ?: ""
            else -> JSONObject().put("uri", uri.toString()).put("name", displayName(context, uri)).toString()
        }
        onPicked(kind, value)
    }

    override fun onMainRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onMainRequestPermissionsResult(requestCode, permissions, grantResults)
        val kind = PERMISSION_REQUESTS.entries.firstOrNull { it.value == requestCode }?.key ?: return
        onPermission(kind, grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
    }

    private fun startPick(kind: String) {
        val activity = activity ?: return
        if (pendingPick.isNotEmpty()) return
        val intent = when (kind) {
            KIND_MUSIC, KIND_IGNORED -> Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
            )
            KIND_IMAGE -> Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("image/*")
            KIND_SOUND -> Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("audio/*")
            KIND_PLUGIN, KIND_THEME -> Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*")
                .putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/zip", "application/x-zip-compressed", "application/octet-stream"))
            KIND_SOUNDFONT, KIND_TEXT -> Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*")
            else -> return
        }
        pendingPick = kind
        activity.startActivityForResult(intent, PICK_REQUEST)
    }

    private fun askPermission(kind: String) {
        val permission = permissionFor(kind) ?: return
        if (granted(activity ?: return, kind)) return
        activity?.requestPermissions(arrayOf(permission), PERMISSION_REQUESTS[kind] ?: return)
    }

    companion object {
        private const val PICK_REQUEST = 4103
        private const val LIBRARY_DEBOUNCE = 1500L
        private const val KIND_MUSIC = "music"
        private const val KIND_IGNORED = "ignored"
        private const val KIND_IMAGE = "image"
        private const val KIND_SOUND = "sound"
        private const val KIND_PLUGIN = "plugin"
        private const val KIND_THEME = "theme"
        private const val KIND_SOUNDFONT = "soundfont"
        private const val KIND_TEXT = "text"
        private const val LEGACY_FOLDERS = "music_library_folders_v1"
        private val PERMISSION_REQUESTS = mapOf("notification" to 4102, "record" to 4104)
        private var multicastLock: WifiManager.MulticastLock? = null
        private var wifiLock: WifiManager.WifiLock? = null

        @Volatile private var bridge: NariBridge? = null
        @Volatile private var appContext: Context? = null
        @Volatile private var loaded = false

        @JvmStatic external fun init(context: Context)
        @JvmStatic external fun onPicked(kind: String, value: String)
        @JvmStatic external fun onPermission(kind: String, granted: Boolean)
        @JvmStatic external fun onLibraryChanged()
        @JvmStatic external fun onCommand(name: String, value: Long)
        @JvmStatic external fun onNowPlaying()
        @JvmStatic external fun onLink(url: String)

        @JvmStatic
        fun command(name: String, value: Long) {
            if (loaded) onCommand(name, value)
        }

        @JvmStatic
        fun webview(request: String): String = NariWebView.handle(bridge?.activity, request)

        @JvmStatic
        fun openFd(uri: String): Int = try {
            appContext?.contentResolver?.openFileDescriptor(Uri.parse(uri), "r")?.detachFd() ?: -1
        } catch (_: Exception) {
            -1
        }

        @JvmStatic
        fun discover(request: String): String {
            val context = appContext ?: return "{}"
            return try {
                Discovery.run(context, request)
            } catch (error: Exception) {
                android.util.Log.w("NariDiscovery", "Discovery failed", error)
                "{}"
            }
        }

        @JvmStatic
        fun hasPermission(kind: String): Boolean = appContext?.let { granted(it, kind) } ?: false

        @JvmStatic
        fun requestPermission(kind: String) {
            Handler(Looper.getMainLooper()).post { bridge?.askPermission(kind) }
        }

        @JvmStatic
        fun pick(kind: String) {
            Handler(Looper.getMainLooper()).post { bridge?.startPick(kind) }
        }

        @JvmStatic
        fun releaseFolder(uri: String) {
            try {
                appContext?.contentResolver?.releasePersistableUriPermission(
                    Uri.parse(uri), Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                )
            } catch (_: Exception) {
            }
        }

        @JvmStatic
        fun vault(request: String): String = runCatching {
            val (action, payload) = request.split(":", limit = 2)
            val bytes = Base64.decode(payload, Base64.NO_WRAP)
            val cipher = Cipher.getInstance(VAULT_CIPHER)
            val result = if (action == "wrap") {
                cipher.init(Cipher.ENCRYPT_MODE, vaultKey())
                cipher.iv + cipher.doFinal(bytes)
            } else {
                cipher.init(Cipher.DECRYPT_MODE, vaultKey(), GCMParameterSpec(VAULT_TAG_BITS, bytes, 0, VAULT_IV_BYTES))
                cipher.doFinal(bytes, VAULT_IV_BYTES, bytes.size - VAULT_IV_BYTES)
            }
            Base64.encodeToString(result, Base64.NO_WRAP)
        }.getOrDefault("")

        private fun vaultKey(): SecretKey {
            val store = KeyStore.getInstance(VAULT_STORE).apply { load(null) }
            (store.getKey(VAULT_ALIAS, null) as? SecretKey)?.let { return it }
            val spec = KeyGenParameterSpec.Builder(VAULT_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
            return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, VAULT_STORE).apply { init(spec) }.generateKey()
        }

        @JvmStatic
        fun system(query: String): String {
            val context = appContext ?: return ""
            if (query.startsWith("install_apk:")) return installApk(context, query.removePrefix("install_apk:"))
            return when (query) {
                "battery_level" -> battery(context)?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
                    ?.takeIf { it in 0..100 }?.toString() ?: "-1"
                "battery_charging" -> charging(context).toString()
                "network" -> network(context)
                "output_device" -> outputDevice(context)
                "reduce_motion" -> (Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f).toString()
                "multicast:on", "multicast:off" -> { castLocks(context, multicast = query.endsWith("on")); "" }
                "wifi_lock:on", "wifi_lock:off" -> { castLocks(context, wifi = query.endsWith("on")); "" }
                else -> ""
            }
        }

        private fun installApk(context: Context, path: String): String {
            if (Build.VERSION.SDK_INT >= 26 && !context.packageManager.canRequestPackageInstalls()) {
                val settings = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                return runCatching { context.startActivity(settings); "permission" }.getOrDefault("error")
            }
            val uri = runCatching { FileProvider.getUriForFile(context, "${context.packageName}.nari.updates", File(path)) }.getOrNull() ?: return "error"
            val install = Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            return runCatching { context.startActivity(install); "ok" }.getOrDefault("error")
        }

        private fun castLocks(context: Context, multicast: Boolean? = null, wifi: Boolean? = null) {
            val manager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return
            multicast?.let { held ->
                val lock = multicastLock ?: manager.createMulticastLock("nari-cast").apply { setReferenceCounted(false) }.also { multicastLock = it }
                if (held && !lock.isHeld) lock.acquire() else if (!held && lock.isHeld) lock.release()
            }
            wifi?.let { held ->
                val mode = if (Build.VERSION.SDK_INT >= 29) WifiManager.WIFI_MODE_FULL_LOW_LATENCY else WifiManager.WIFI_MODE_FULL_HIGH_PERF
                val lock = wifiLock ?: manager.createWifiLock(mode, "nari-cast").apply { setReferenceCounted(false) }.also { wifiLock = it }
                if (held && !lock.isHeld) lock.acquire() else if (!held && lock.isHeld) lock.release()
            }
        }

        @JvmStatic
        fun updateSession(state: String) {
            NariSessionService.update(state)
        }

        @JvmStatic
        fun discord(payload: String) {
            appContext?.let { DiscordPresence.update(it, payload) }
        }

        private fun permissionFor(kind: String): String? = when (kind) {
            "notification" -> if (Build.VERSION.SDK_INT >= 33) Manifest.permission.POST_NOTIFICATIONS else null
            "record" -> Manifest.permission.RECORD_AUDIO
            else -> null
        }

        private fun granted(context: Context, kind: String): Boolean {
            val permission = permissionFor(kind) ?: return true
            return context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
        }

        private fun battery(context: Context) = context.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager

        private fun charging(context: Context): Boolean {
            val state = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)) ?: return false
            val status = state.getIntExtra(BatteryManager.EXTRA_STATUS, BatteryManager.BATTERY_STATUS_UNKNOWN)
            return state.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0 ||
                status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL
        }

        private fun outputDevice(context: Context): String {
            val audio = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return "{}"
            val device = audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                .mapNotNull { info -> OUTPUT_KINDS[info.type]?.let { info to it } }
                .minByOrNull { OUTPUT_ORDER.indexOf(it.second) }
                ?: return "{}"
            return JSONObject().put("kind", device.second).put("name", device.first.productName?.toString() ?: "").toString()
        }

        private val OUTPUT_ORDER = listOf("earbuds", "wireless_speaker", "headphones", "usb", "speaker")
        private val OUTPUT_KINDS = buildMap {
            put(AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, "earbuds")
            put(AudioDeviceInfo.TYPE_WIRED_HEADPHONES, "headphones")
            put(AudioDeviceInfo.TYPE_WIRED_HEADSET, "headphones")
            put(AudioDeviceInfo.TYPE_USB_HEADSET, "headphones")
            put(AudioDeviceInfo.TYPE_USB_DEVICE, "usb")
            put(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, "speaker")
            if (Build.VERSION.SDK_INT >= 31) {
                put(AudioDeviceInfo.TYPE_BLE_HEADSET, "earbuds")
                put(AudioDeviceInfo.TYPE_BLE_SPEAKER, "wireless_speaker")
            }
        }

        @Suppress("DEPRECATION")
        private fun network(context: Context): String {
            val none = JSONObject().put("connection", "none").put("level", 0).toString()
            val connectivity = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return none
            val capabilities = connectivity.activeNetwork?.let { connectivity.getNetworkCapabilities(it) } ?: return none
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) {
                return JSONObject().put("connection", "ethernet").put("level", 4).toString()
            }
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
                val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                val level = wifi?.connectionInfo?.rssi?.let { WifiManager.calculateSignalLevel(it, 5) } ?: 0
                return JSONObject().put("connection", "wireless").put("level", level.coerceIn(0, 4)).toString()
            }
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) {
                val telephony = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
                val level = if (Build.VERSION.SDK_INT >= 28) {
                    try {
                        telephony?.signalStrength?.level ?: 0
                    } catch (_: Exception) {
                        0
                    }
                } else {
                    0
                }
                return JSONObject().put("connection", "wireless").put("level", level.coerceIn(0, 4)).toString()
            }
            return none
        }

        private fun folder(context: Context, uri: Uri): JSONObject? {
            val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            try {
                context.contentResolver.takePersistableUriPermission(uri, flags)
            } catch (_: Exception) {
                try {
                    context.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                } catch (_: Exception) {
                    return null
                }
            }
            return folderJson(uri, "")
        }

        private fun folderJson(uri: Uri, storedName: String): JSONObject {
            val documentId = try {
                DocumentsContract.getTreeDocumentId(uri)
            } catch (_: Exception) {
                uri.toString()
            }
            val name = storedName.ifEmpty {
                documentId.substringAfter(':', documentId).substringAfterLast('/').ifEmpty { documentId }
            }
            return JSONObject().put("uri", uri.toString()).put("name", name).put("document_id", documentId)
        }

        private fun displayName(context: Context, uri: Uri): String = try {
            context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            } ?: ""
        } catch (_: Exception) {
            ""
        }

        private fun migrateFolders(context: Context) {
            val target = File(context.filesDir, "library/folders.json")
            val preferences = context.getSharedPreferences(LEGACY_FOLDERS, Context.MODE_PRIVATE)
            if (target.exists() || preferences.all.isEmpty()) return
            val convert = { key: String ->
                val stored = try {
                    JSONArray(preferences.getString(key, null) ?: "[]")
                } catch (_: Exception) {
                    JSONArray()
                }
                JSONArray().apply {
                    for (index in 0 until stored.length()) {
                        val item = stored.optJSONObject(index) ?: continue
                        val uri = item.optString("uri")
                        if (uri.isNotEmpty()) put(folderJson(Uri.parse(uri), item.optString("name")))
                    }
                }
            }
            val folders = JSONObject()
                .put("music", convert("music_folders"))
                .put("ignored", convert("ignored_folders"))
            target.parentFile?.mkdirs()
            target.writeText(folders.toString())
            preferences.edit().clear().apply()
        }
    }
}
