package li.taurusag.actionhub.viewer

import android.os.Handler
import android.os.Looper
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import java.util.concurrent.TimeUnit

class ViewerRelayClient(
    private val onStatus: (String) -> Unit,
    private val onEvent: (JSONObject) -> Unit,
) {
    private val httpClient = OkHttpClient.Builder()
        .pingInterval(20, TimeUnit.SECONDS)
        .build()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var webSocket: WebSocket? = null
    private var presenceRunnable: Runnable? = null

    fun send(payload: JSONObject) {
        webSocket?.send(payload.toString())
    }

    fun connect() {
        onStatus("connecting...")
        val request = Request.Builder()
            .url("wss://actionhub.app/?role=viewer&room=actionhub&token=$relayToken")
            .build()
        webSocket = httpClient.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(openedSocket: WebSocket, response: Response) {
                mainHandler.post {
                    onStatus("connected")
                    openedSocket.send(JSONObject(mapOf("type" to "hello", "device" to "daylight-viewer")).toString())
                    startPresence(openedSocket)
                }
            }

            override fun onMessage(socket: WebSocket, text: String) {
                if (text == "pong") return
                val payload = try {
                    JSONObject(text)
                } catch (parseError: Exception) {
                    return
                }
                mainHandler.post { onEvent(payload) }
            }

            override fun onFailure(socket: WebSocket, failure: Throwable, response: Response?) {
                mainHandler.post { handleDisconnect(failure.message ?: "failure") }
            }

            override fun onClosed(socket: WebSocket, code: Int, reason: String) {
                mainHandler.post { handleDisconnect("closed $code") }
            }
        })
    }

    private fun startPresence(socket: WebSocket) {
        stopPresence()
        val runnable = object : Runnable {
            override fun run() {
                socket.send(JSONObject(mapOf("type" to "presence")).toString())
                mainHandler.postDelayed(this, 10_000)
            }
        }
        presenceRunnable = runnable
        mainHandler.postDelayed(runnable, 10_000)
    }

    private fun stopPresence() {
        presenceRunnable?.let(mainHandler::removeCallbacks)
        presenceRunnable = null
    }

    private fun handleDisconnect(reason: String) {
        stopPresence()
        webSocket?.cancel()
        webSocket = null
        onStatus("disconnected ($reason), retrying...")
        mainHandler.postDelayed({ connect() }, 3_000)
    }
}
