package li.taurusag.actionhub.keyboard

import android.util.Base64
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject

class ScribeSocket(
    private val onPartial: (String) -> Unit,
    private val onCommitted: (String) -> Unit,
    private val onStatus: (String) -> Unit,
    private val onClosed: () -> Unit,
) {
    private val httpClient = OkHttpClient.Builder()
        .pingInterval(20, java.util.concurrent.TimeUnit.SECONDS)
        .build()
    private var webSocket: WebSocket? = null

    val isOpen: Boolean
        get() = webSocket != null

    fun connect(token: String) {
        val url = "wss://api.elevenlabs.io/v1/speech-to-text/realtime" +
            "?model_id=scribe_v2_realtime" +
            "&audio_format=pcm_$SAMPLE_RATE" +
            "&commit_strategy=manual" +
            "&token=$token"
        onStatus("scribe: connecting")
        webSocket = httpClient.newWebSocket(
            Request.Builder().url(url).build(),
            object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    onStatus("scribe: connected")
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    handleServerMessage(text)
                }

                override fun onFailure(webSocket: WebSocket, failure: Throwable, response: Response?) {
                    onStatus("scribe: failed ${failure.message}")
                    this@ScribeSocket.webSocket = null
                    onClosed()
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                    onStatus("scribe: closed $code")
                    this@ScribeSocket.webSocket = null
                    onClosed()
                }
            },
        )
    }

    fun sendAudio(audioChunk: ByteArray, commit: Boolean = false) {
        val payload = JSONObject()
            .put("message_type", "input_audio_chunk")
            .put("audio_base_64", Base64.encodeToString(audioChunk, Base64.NO_WRAP))
            .put("commit", commit)
            .put("sample_rate", SAMPLE_RATE)
        webSocket?.send(payload.toString())
    }

    fun close() {
        webSocket?.cancel()
        webSocket = null
    }

    private fun handleServerMessage(text: String) {
        val payload = runCatching { JSONObject(text) }.getOrNull() ?: return
        val transcriptText = payload.optString("text", "")
        when (payload.optString("message_type")) {
            "partial_transcript" -> onPartial(transcriptText)
            "committed_transcript" -> onCommitted(transcriptText)
        }
    }

    companion object {
        const val SAMPLE_RATE = 16000
    }
}
