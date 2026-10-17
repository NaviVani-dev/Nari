package org.navivani.musicservice

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.common.SimpleBasePlayer
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import org.json.JSONObject
import java.io.File

internal const val EXTRA_OPEN_NOW_PLAYING = "org.navivani.musicservice.OPEN_NOW_PLAYING"
internal const val LINK_SCHEME = "nari"
internal const val VAULT_STORE = "AndroidKeyStore"
internal const val VAULT_ALIAS = "nari_vault"
internal const val VAULT_CIPHER = "AES/GCM/NoPadding"
internal const val VAULT_TAG_BITS = 128
internal const val VAULT_IV_BYTES = 12

@UnstableApi
class NariSessionService : MediaSessionService() {

    private inner class RustPlayer : SimpleBasePlayer(Looper.getMainLooper()) {

        override fun getState(): State {
            val state = current
            val id = state.optString("id")
            val playing = state.optBoolean("playing")
            val builder = State.Builder()
                .setAvailableCommands(COMMANDS)
                .setPlayWhenReady(playing, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
            if (id.isEmpty()) {
                return builder.setPlaybackState(Player.STATE_IDLE).setPlaylist(emptyList()).build()
            }
            val metadata = MediaMetadata.Builder()
                .setTitle(state.optString("title"))
                .setArtist(state.optString("artist"))
                .setAlbumTitle(state.optString("album"))
                .apply {
                    val cover = state.optString("cover")
                    if (cover.isNotEmpty() && File(cover).exists()) setArtworkUri(Uri.fromFile(File(cover)))
                }
                .build()
            val item = MediaItemData.Builder(id)
                .setMediaItem(MediaItem.Builder().setMediaId(id).setMediaMetadata(metadata).build())
                .setMediaMetadata(metadata)
                .setDurationUs(if (state.optBoolean("live")) C.TIME_UNSET else state.optLong("duration") * 1000L)
                .setIsSeekable(!state.optBoolean("live"))
                .setIsDynamic(state.optBoolean("live"))
                .build()
            val position = state.optLong("position")
            return builder
                .setPlaylist(listOf(item))
                .setCurrentMediaItemIndex(0)
                .setPlaybackState(Player.STATE_READY)
                .setContentPositionMs(
                    if (playing) PositionSupplier.getExtrapolating(position, 1f) else PositionSupplier.getConstant(position)
                )
                .build()
        }

        override fun handleSetPlayWhenReady(playWhenReady: Boolean): ListenableFuture<*> {
            NariBridge.command(if (playWhenReady) "play" else "pause", 0L)
            return Futures.immediateVoidFuture()
        }

        override fun handleSeek(mediaItemIndex: Int, positionMs: Long, seekCommand: Int): ListenableFuture<*> {
            when (seekCommand) {
                Player.COMMAND_SEEK_TO_NEXT, Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM -> NariBridge.command("next", 0L)
                Player.COMMAND_SEEK_TO_PREVIOUS, Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM -> NariBridge.command("previous", 0L)
                else -> NariBridge.command("seek", positionMs.coerceAtLeast(0L))
            }
            return Futures.immediateVoidFuture()
        }

        override fun handleStop(): ListenableFuture<*> {
            NariBridge.command("stop", 0L)
            return Futures.immediateVoidFuture()
        }

        override fun handleRelease(): ListenableFuture<*> = Futures.immediateVoidFuture()

        fun refresh() = invalidateState()
    }

    private var session: MediaSession? = null
    private var player: RustPlayer? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var focusRequest: AudioFocusRequest? = null
    private var resumeOnFocus = false
    private var noisyRegistered = false

    private val noisy = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) NariBridge.command("pause", 0L)
        }
    }

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS -> {
                resumeOnFocus = false
                NariBridge.command("pause", 0L)
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                resumeOnFocus = current.optBoolean("playing")
                NariBridge.command("pause", 0L)
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> NariBridge.command("duck", 1L)
            AudioManager.AUDIOFOCUS_GAIN -> {
                NariBridge.command("duck", 0L)
                if (resumeOnFocus) NariBridge.command("play", 0L)
                resumeOnFocus = false
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        val created = RustPlayer()
        player = created
        val builder = MediaSession.Builder(this, created)
        launchIntent()?.let { builder.setSessionActivity(it) }
        session = builder.build()
        instance = this
        apply()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = session

    override fun onTaskRemoved(rootIntent: Intent?) {
        if (!current.optBoolean("playing")) stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        setActive(false)
        session?.release()
        session = null
        player = null
        super.onDestroy()
    }

    private fun apply() {
        setActive(current.optBoolean("playing"))
        player?.refresh()
    }

    private fun setActive(playing: Boolean) {
        val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (playing) {
            if (wakeLock == null) {
                val power = getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "nari:playback").also {
                    it.setReferenceCounted(false)
                    it.acquire()
                }
            }
            if (!noisyRegistered) {
                val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
                if (Build.VERSION.SDK_INT >= 33) registerReceiver(noisy, filter, Context.RECEIVER_NOT_EXPORTED) else registerReceiver(noisy, filter)
                noisyRegistered = true
            }
            if (focusRequest == null) {
                val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                            .build()
                    )
                    .setOnAudioFocusChangeListener(focusListener, Handler(Looper.getMainLooper()))
                    .build()
                if (audio.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) focusRequest = request
            }
            return
        }
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        if (noisyRegistered) {
            unregisterReceiver(noisy)
            noisyRegistered = false
        }
        if (!resumeOnFocus) {
            focusRequest?.let { audio.abandonAudioFocusRequest(it) }
            focusRequest = null
        }
    }

    private fun launchIntent(): PendingIntent? {
        val intent = packageManager.getLaunchIntentForPackage(packageName) ?: return null
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        intent.putExtra(EXTRA_OPEN_NOW_PLAYING, true)
        return PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    companion object {
        private val COMMANDS = Player.Commands.Builder().addAll(
            Player.COMMAND_PLAY_PAUSE,
            Player.COMMAND_STOP,
            Player.COMMAND_SEEK_TO_NEXT,
            Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,
            Player.COMMAND_SEEK_TO_PREVIOUS,
            Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,
            Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM,
            Player.COMMAND_GET_CURRENT_MEDIA_ITEM,
            Player.COMMAND_GET_TIMELINE,
            Player.COMMAND_GET_METADATA,
            Player.COMMAND_RELEASE
        ).build()

        @Volatile private var current = JSONObject()
        @Volatile private var instance: NariSessionService? = null
        private val main = Handler(Looper.getMainLooper())

        fun update(state: String) {
            val parsed = try {
                JSONObject(state)
            } catch (_: Exception) {
                return
            }
            main.post {
                current = parsed
                instance?.apply()
            }
        }
    }
}
