package li.taurusag.actionhub.keyboard

import android.Manifest
import android.app.Activity
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.InputType
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class EnrollmentActivity : Activity() {
    private lateinit var keyVault: KeyVault
    private lateinit var yubiKeyPort: YubiKeyPort
    private lateinit var apiKeyField: EditText
    private lateinit var statusLog: TextView
    private lateinit var logScrollView: ScrollView
    private val mainHandler = Handler(Looper.getMainLooper())
    private val timestampFormat = SimpleDateFormat("HH:mm:ss", Locale.US)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        keyVault = KeyVault(this)
        setContentView(buildLayout())
        yubiKeyPort = YubiKeyPort(this)
        yubiKeyPort.onDeviceChange = { attached ->
            mainHandler.post { appendStatus(if (attached) "yubikey attached" else "yubikey detached") }
        }
        yubiKeyPort.startDiscovery()
        appendStatus(if (keyVault.isEnrolled()) "vault: key wrapped and stored" else "vault: empty")
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 1)
        }
    }

    override fun onDestroy() {
        yubiKeyPort.stopDiscovery()
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        val granted = grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
        appendStatus(if (granted) "mic permission granted" else "mic permission denied, keyboard cannot listen")
    }

    private fun enroll() {
        val apiKey = apiKeyField.text.toString().trim()
        if (apiKey.isEmpty()) {
            appendStatus("paste the api key first")
            return
        }
        val device = yubiKeyPort.attachedDevice
        if (device == null) {
            appendStatus("plug in the yubikey")
            return
        }
        appendStatus("touch the yubikey to create the credential, then touch again to wrap")
        keyVault.enroll(device, apiKey) { enrolled, message ->
            mainHandler.post {
                appendStatus(message)
                if (enrolled) {
                    apiKeyField.setText("")
                    (getSystemService(CLIPBOARD_SERVICE) as ClipboardManager).clearPrimaryClip()
                    appendStatus("clipboard cleared")
                }
            }
        }
    }

    private fun verify() {
        val device = yubiKeyPort.attachedDevice
        if (device == null) {
            appendStatus("plug in the yubikey")
            return
        }
        appendStatus("touch the yubikey to unwrap")
        keyVault.unwrap(device) { apiKey, message ->
            if (apiKey == null) {
                mainHandler.post { appendStatus(message) }
                return@unwrap
            }
            Thread {
                try {
                    val token = TokenMinter.mint(apiKey)
                    mainHandler.post { appendStatus("verified: minted ${token.take(12)}…") }
                } catch (mintError: Exception) {
                    mainHandler.post { appendStatus("mint failed: ${mintError.message}") }
                }
            }.start()
        }
    }

    private fun appendStatus(message: String) {
        statusLog.append("${timestampFormat.format(Date())}  $message\n")
        logScrollView.post { logScrollView.fullScroll(ScrollView.FOCUS_DOWN) }
    }

    private fun buildLayout(): ScrollView {
        val root = LinearLayout(this)
        root.orientation = LinearLayout.VERTICAL
        root.setBackgroundColor(Color.WHITE)
        root.setPadding(dp(16), dp(16), dp(16), dp(16))

        val title = TextView(this)
        title.text = "ActionHub Voice Keyboard — enrollment"
        title.textSize = 20f
        title.setTextColor(Color.BLACK)
        root.addView(title)

        apiKeyField = EditText(this)
        apiKeyField.hint = "paste the elevenlabs scribe api key"
        apiKeyField.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
        root.addView(apiKeyField)

        addButton(root, "wrap key to yubikey") { enroll() }
        addButton(root, "verify: unwrap + mint token") { verify() }
        addButton(root, "enable keyboard in system settings") {
            startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
        }

        statusLog = TextView(this)
        statusLog.textSize = 14f
        statusLog.setTextColor(Color.DKGRAY)
        logScrollView = ScrollView(this)
        logScrollView.addView(statusLog)
        root.addView(logScrollView, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(320)))

        val outerScrollView = ScrollView(this)
        outerScrollView.addView(root)
        return outerScrollView
    }

    private fun addButton(container: LinearLayout, label: String, onClick: () -> Unit) {
        val button = Button(this)
        button.text = label
        button.isAllCaps = false
        button.setOnClickListener { onClick() }
        container.addView(button, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(52)))
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()
}
