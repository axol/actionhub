package li.taurusag.actionhub.viewer

import android.app.Activity
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.view.Gravity
import android.view.WindowManager
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import org.json.JSONObject
import java.security.MessageDigest
import java.security.SecureRandom
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class MainActivity : Activity() {
    private lateinit var statusView: TextView
    private lateinit var partialView: TextView
    private lateinit var transcriptView: TextView
    private lateinit var scrollView: ScrollView
    private lateinit var lockLayout: LinearLayout
    private lateinit var relayClient: ViewerRelayClient
    private lateinit var yubiKeyGate: YubiKeyGate
    private val mainHandler = Handler(Looper.getMainLooper())
    private val timestampFormat = SimpleDateFormat("HH:mm:ss", Locale.US)
    private val maximumTranscriptCharacters = 60_000
    private val lockAfterMilliseconds = 5L * 60 * 1000
    private val lockRunnable = Runnable { engageLock() }
    private var pendingActionJson: String? = null
    private var yubiKeyAttached = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContentView(buildLayout())
        yubiKeyGate = YubiKeyGate(this)
        yubiKeyGate.onDeviceChange = { attached ->
            yubiKeyAttached = attached
            mainHandler.post { appendTranscript(if (attached) "· yubikey attached" else "· yubikey detached") }
        }
        yubiKeyGate.startDiscovery()
        relayClient = ViewerRelayClient(
            onStatus = { status -> statusView.text = "relay: $status" },
            onEvent = { payload -> renderEvent(payload) },
        )
        relayClient.connect()
        if (storedCredentialId() != null) {
            engageLock()
        } else {
            rescheduleLock()
        }
    }

    private fun buildLayout(): FrameLayout {
        statusView = TextView(this)
        statusView.textSize = 14f
        statusView.typeface = Typeface.MONOSPACE
        partialView = TextView(this)
        partialView.textSize = 17f
        partialView.setTypeface(null, Typeface.ITALIC)
        transcriptView = TextView(this)
        transcriptView.textSize = 17f
        transcriptView.setTextIsSelectable(true)
        transcriptView.setLineSpacing(0f, 1.25f)
        scrollView = ScrollView(this)
        scrollView.addView(transcriptView)
        val pairButton = Button(this)
        pairButton.text = "pair"
        pairButton.setOnClickListener { startPairing() }
        val pingButton = Button(this)
        pingButton.text = "signed ping"
        pingButton.setOnClickListener { startSignedAction() }
        val lockButton = Button(this)
        lockButton.text = "lock"
        lockButton.setOnClickListener { lockNow() }
        val buttonRow = LinearLayout(this)
        buttonRow.orientation = LinearLayout.HORIZONTAL
        buttonRow.addView(pairButton)
        buttonRow.addView(pingButton)
        buttonRow.addView(lockButton)
        val mainLayout = LinearLayout(this)
        mainLayout.orientation = LinearLayout.VERTICAL
        mainLayout.setPadding(48, 48, 48, 48)
        mainLayout.addView(statusView)
        mainLayout.addView(buttonRow)
        mainLayout.addView(partialView)
        mainLayout.addView(scrollView)
        lockLayout = LinearLayout(this)
        lockLayout.orientation = LinearLayout.VERTICAL
        lockLayout.gravity = Gravity.CENTER
        lockLayout.setBackgroundColor(Color.WHITE)
        lockLayout.visibility = LinearLayout.GONE
        val lockText = TextView(this)
        lockText.text = "locked"
        lockText.textSize = 32f
        lockText.gravity = Gravity.CENTER
        val unlockButton = Button(this)
        unlockButton.text = "unlock with yubikey"
        unlockButton.setOnClickListener { attemptUnlock() }
        lockLayout.addView(lockText)
        lockLayout.addView(unlockButton)
        val root = FrameLayout(this)
        root.addView(mainLayout)
        root.addView(lockLayout)
        return root
    }

    override fun onUserInteraction() {
        super.onUserInteraction()
        if (lockLayout.visibility != LinearLayout.VISIBLE) {
            rescheduleLock()
        }
    }

    private fun rescheduleLock() {
        mainHandler.removeCallbacks(lockRunnable)
        if (storedCredentialId() != null) {
            mainHandler.postDelayed(lockRunnable, lockAfterMilliseconds)
        }
    }

    private fun engageLock() {
        lockLayout.visibility = LinearLayout.VISIBLE
    }

    private fun lockNow() {
        if (storedCredentialId() == null) {
            appendTranscript("✗ pair first, otherwise the lock has no key")
            return
        }
        mainHandler.removeCallbacks(lockRunnable)
        engageLock()
    }

    private fun attemptUnlock() {
        val credentialId = storedCredentialId()
        if (credentialId == null) {
            lockLayout.visibility = LinearLayout.GONE
            return
        }
        if (!yubiKeyAttached) {
            appendTranscript("✗ unlock needs the yubikey plugged in")
            return
        }
        val localChallenge = ByteArray(32)
        SecureRandom().nextBytes(localChallenge)
        yubiKeyGate.sign(credentialId, localChallenge) { assertion, message ->
            mainHandler.post {
                if (assertion != null && assertion.userVerified) {
                    lockLayout.visibility = LinearLayout.GONE
                    appendTranscript("· unlocked")
                    rescheduleLock()
                } else {
                    appendTranscript("✗ unlock failed: $message")
                }
            }
        }
    }

    private fun startPairing() {
        yubiKeyGate.createCredential { authenticatorData, message ->
            mainHandler.post {
                appendTranscript("· $message")
                if (authenticatorData == null) return@post
                val credentialId = YubiKeyGate.extractCredentialId(authenticatorData)
                getPreferences(MODE_PRIVATE).edit()
                    .putString("credentialId", Base64.encodeToString(credentialId, Base64.NO_WRAP))
                    .apply()
                relayClient.send(
                    JSONObject(
                        mapOf(
                            "type" to "pair",
                            "authenticator_data" to Base64.encodeToString(authenticatorData, Base64.NO_WRAP),
                        )
                    )
                )
                appendTranscript("· pairing request sent, confirm on the mac (press y)")
                rescheduleLock()
            }
        }
    }

    private fun startSignedAction() {
        if (storedCredentialId() == null) {
            appendTranscript("✗ pair first")
            return
        }
        pendingActionJson = JSONObject(mapOf("kind" to "ping", "note" to "hello from viewer")).toString()
        relayClient.send(JSONObject(mapOf("type" to "challenge_request")))
        appendTranscript("· challenge requested")
    }

    private fun completeSignedAction(nonce: String) {
        val actionJson = pendingActionJson ?: return
        pendingActionJson = null
        val credentialId = storedCredentialId() ?: return
        val nonceBytes = Base64.decode(nonce, Base64.NO_WRAP)
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update(actionJson.toByteArray())
        digest.update(nonceBytes)
        val clientDataHash = digest.digest()
        appendTranscript("· signing, touch the yubikey...")
        yubiKeyGate.sign(credentialId, clientDataHash) { assertion, message ->
            mainHandler.post {
                if (assertion == null) {
                    appendTranscript("✗ $message")
                    return@post
                }
                relayClient.send(
                    JSONObject(
                        mapOf(
                            "type" to "action",
                            "action" to actionJson,
                            "nonce" to nonce,
                            "credential_id" to Base64.encodeToString(credentialId, Base64.NO_WRAP),
                            "authenticator_data" to Base64.encodeToString(assertion.authenticatorData, Base64.NO_WRAP),
                            "signature" to Base64.encodeToString(assertion.signature, Base64.NO_WRAP),
                        )
                    )
                )
                appendTranscript("· signed action sent")
            }
        }
    }

    private fun storedCredentialId(): ByteArray? {
        val encodedId = getPreferences(MODE_PRIVATE).getString("credentialId", null) ?: return null
        return Base64.decode(encodedId, Base64.NO_WRAP)
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
            "utterance" -> {
                if (payload.optString("kind") == "committed") {
                    partialView.text = ""
                    val text = payload.optString("text").trim()
                    if (text.isNotEmpty()) appendTranscript("you: $text")
                } else {
                    partialView.text = "… ${payload.optString("text").trim()}"
                }
            }
            "message" -> appendTranscript("→ sent: ${payload.optString("text")}")
            "challenge" -> completeSignedAction(payload.optString("nonce"))
            "paired" -> appendTranscript("✓ paired with mac")
            "pair_rejected" -> appendTranscript("✗ pairing rejected on the mac")
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

    override fun onStop() {
        super.onStop()
        if (storedCredentialId() != null) {
            mainHandler.removeCallbacks(lockRunnable)
            engageLock()
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        yubiKeyGate.stopDiscovery()
    }
}
