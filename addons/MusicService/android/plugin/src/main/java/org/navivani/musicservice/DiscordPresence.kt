package org.navivani.musicservice

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import com.discord.socialsdk.rpc.IDiscordRpcCallback
import com.discord.socialsdk.rpc.IDiscordRpcConnection
import com.discord.socialsdk.rpc.IDiscordRpcService
import org.json.JSONObject

object DiscordPresence {
    private const val TAG = "NariDiscord"
    private const val PACKAGE = "com.discord"
    private const val ACTION = "com.discord.socialsdk.rpc.IDiscordRpcService"
    private const val VERSION = "1"

    private val handler = Handler(Looper.getMainLooper())
    private var context: Context? = null
    private var app = 0L
    private var activity: Any = JSONObject.NULL
    private var bound = false
    private var ready = false
    private var nonce = 0L
    private var connection: IDiscordRpcConnection? = null

    fun update(context: Context, payload: String) {
        handler.post {
            val json = try { JSONObject(payload) } catch (_: Exception) { return@post }
            this.context = context.applicationContext
            app = json.optString("app").toLongOrNull() ?: return@post
            activity = json.opt("activity") ?: JSONObject.NULL
            when {
                ready -> send()
                !bound && activity != JSONObject.NULL -> bind()
            }
        }
    }

    private fun bind() {
        val context = context ?: return
        bound = try {
            context.bindService(Intent(ACTION).setPackage(PACKAGE), service, Context.BIND_AUTO_CREATE)
        } catch (error: Exception) {
            Log.w(TAG, "Discord is unavailable", error)
            false
        }
    }

    private fun send() {
        val connection = connection ?: return
        val frame = JSONObject()
            .put("cmd", "SET_ACTIVITY")
            .put("nonce", (++nonce).toString())
            .put("args", JSONObject().put("activity", activity))
        try {
            connection.sendFrame(frame.toString())
        } catch (error: Exception) {
            Log.w(TAG, "The presence could not be sent", error)
            reset()
            return
        }
        if (activity == JSONObject.NULL) reset()
    }

    private fun reset() {
        try {
            connection?.disconnect()
        } catch (_: Exception) {
        }
        if (bound) {
            try {
                context?.unbindService(service)
            } catch (_: Exception) {
            }
        }
        connection = null
        bound = false
        ready = false
    }

    private val callback = object : IDiscordRpcCallback.Stub() {
        override fun onFrame(frame: String?) {
            handler.post {
                val event = try { JSONObject(frame ?: "").optString("evt") } catch (_: Exception) { "" }
                if (event == "READY") {
                    ready = true
                    send()
                } else if (event == "ERROR") {
                    Log.w(TAG, "Discord refused the presence: $frame")
                }
            }
        }

        override fun onClose(code: Int, reason: String?) {
            handler.post {
                Log.w(TAG, "Discord closed the presence ($code): $reason")
                reset()
            }
        }
    }

    private val service = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            connection = try {
                IDiscordRpcService.Stub.asInterface(binder).connect(app, VERSION, callback)
            } catch (error: Exception) {
                Log.w(TAG, "Discord rejected the connection", error)
                null
            }
            if (connection == null) reset()
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            reset()
        }
    }
}
