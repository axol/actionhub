package li.taurusag.actionhub.viewer

import android.app.Activity
import android.graphics.Typeface
import android.os.Bundle
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class MainActivity : Activity() {
    private lateinit var statusView: TextView
    private lateinit var transcriptView: TextView
    private lateinit var scrollView: ScrollView
    private lateinit var relayClient: ViewerRelayClient
    private val timestampFormat = SimpleDateFormat("HH:mm:ss", Locale.US)
    private val maximumTranscriptCharacters = 60_000

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        statusView = TextView(this)
        statusView.textSize = 14f
        statusView.typeface = Typeface.MONOSPACE
        transcriptView = TextView(this)
        transcriptView.textSize = 17f
        transcriptView.setTextIsSelectable(true)
        transcriptView.setLineSpacing(0f, 1.25f)
        scrollView = ScrollView(this)
        scrollView.addView(transcriptView)
        val layout = LinearLayout(this)
        layout.orientation = LinearLayout.VERTICAL
        layout.setPadding(48, 48, 48, 48)
        layout.addView(statusView)
        layout.addView(scrollView)
        setContentView(layout)
        relayClient = ViewerRelayClient(
            onStatus = { status -> statusView.text = "relay: $status" },
            onEvent = { payload -> renderEvent(payload) },
        )
        relayClient.connect()
    }

    private fun renderEvent(payload: JSONObject) {
        when (payload.optString("type")) {
            "activity" -> {
                val kind = payload.optString("kind")
                val text = payload.optString("text")
                appendTranscript(formatActivity(kind, text))
            }
            "state" -> appendTranscript("· audio owner: ${payload.optString("audio")}")
            "speak" -> appendTranscript("🔊 ${payload.optString("text")}")
        }
    }

    private fun formatActivity(kind: String, text: String): String {
        return when (kind) {
            "response" -> "claude:\n$text\n"
            "thinking" -> "· thinking"
            "tool_use" -> "· $text"
            "received" -> "✓ $text"
            "error" -> "✗ $text"
            else -> "· $text"
        }
    }

    private fun appendTranscript(line: String) {
        val timestamp = timestampFormat.format(Date())
        transcriptView.append("$timestamp  $line\n")
        val transcriptText = transcriptView.text
        if (transcriptText.length > maximumTranscriptCharacters) {
            transcriptView.text = transcriptText.subSequence(transcriptText.length / 2, transcriptText.length)
        }
        scrollView.post { scrollView.fullScroll(ScrollView.FOCUS_DOWN) }
    }
}
