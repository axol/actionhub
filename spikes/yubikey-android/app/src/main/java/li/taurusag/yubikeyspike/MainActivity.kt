package li.taurusag.yubikeyspike

import android.app.Activity
import android.os.Bundle
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.yubico.yubikit.android.YubiKitManager
import com.yubico.yubikit.android.transport.usb.UsbConfiguration
import com.yubico.yubikit.android.transport.usb.UsbYubiKeyDevice
import com.yubico.yubikit.core.fido.FidoConnection
import com.yubico.yubikit.fido.ctap.Ctap2Session

class MainActivity : Activity() {
    private lateinit var logView: TextView
    private lateinit var yubiKitManager: YubiKitManager
    private var attachedDevice: UsbYubiKeyDevice? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        logView = TextView(this)
        logView.setPadding(32, 32, 32, 64)
        logView.setTextIsSelectable(true)
        val assertionButton = Button(this)
        assertionButton.text = "test fingerprint assertion"
        assertionButton.setOnClickListener { runAssertionTest() }
        val scrollView = ScrollView(this)
        scrollView.addView(logView)
        val layout = LinearLayout(this)
        layout.orientation = LinearLayout.VERTICAL
        layout.setPadding(32, 64, 32, 0)
        layout.addView(assertionButton)
        layout.addView(scrollView)
        setContentView(layout)
        appendLine("plug in the YubiKey Bio via USB-C")
        yubiKitManager = YubiKitManager(this)
        yubiKitManager.startUsbDiscovery(UsbConfiguration()) { device ->
            attachedDevice = device
            appendLine("usb yubikey attached")
            device.requestConnection(FidoConnection::class.java) { result ->
                try {
                    val session = Ctap2Session(result.value)
                    val info = session.info
                    appendLine("ctap2 versions: ${info.versions}")
                    appendLine("options: ${info.options}")
                    appendLine("bio enroll supported: ${info.options.containsKey("bioEnroll")}")
                    appendLine("uv configured: ${info.options["uv"] == true}")
                } catch (sessionError: Exception) {
                    appendLine("ctap2 failed: $sessionError")
                }
            }
        }
    }

    private fun runAssertionTest() {
        val device = attachedDevice
        if (device == null) {
            appendLine("no yubikey attached")
            return
        }
        appendLine("--- assertion test ---")
        device.requestConnection(FidoConnection::class.java) { result ->
            try {
                val session = Ctap2Session(result.value)
                val clientDataHash = ByteArray(32) { 1 }
                val relyingParty = mapOf("id" to "spike.actionhub", "name" to "ActionHub Spike")
                val user = mapOf(
                    "id" to ByteArray(16) { 2 },
                    "name" to "spike",
                    "displayName" to "spike",
                )
                val algorithms = listOf(mapOf("type" to "public-key", "alg" to -7))
                appendLine("creating credential, touch the sensor when the key blinks...")
                val credential = session.makeCredential(
                    clientDataHash,
                    relyingParty,
                    user,
                    algorithms,
                    null,
                    null,
                    mapOf("uv" to true),
                    null,
                    null,
                    null,
                    null,
                )
                val credentialId = extractCredentialId(credential.authenticatorData)
                appendLine("credential created, id ${credentialId.size} bytes")
                appendLine("requesting assertion, touch the sensor again...")
                val assertions = session.getAssertions(
                    "spike.actionhub",
                    clientDataHash,
                    listOf(mapOf("type" to "public-key", "id" to credentialId)),
                    null,
                    mapOf("uv" to true),
                    null,
                    null,
                    null,
                )
                val assertionFlags = assertions.first().authenticatorData[32].toInt()
                val userVerified = (assertionFlags and 0x04) != 0
                appendLine("assertion returned, flags ${Integer.toBinaryString(assertionFlags and 0xff)}")
                appendLine("user verified by fingerprint: $userVerified")
                appendLine(if (userVerified) "--- phase 2 PASS ---" else "--- assertion without UV, check flags ---")
            } catch (assertionError: Exception) {
                appendLine("assertion test failed: $assertionError")
            }
        }
    }

    private fun extractCredentialId(authenticatorData: ByteArray): ByteArray {
        val credentialIdLength = ((authenticatorData[53].toInt() and 0xff) shl 8) or (authenticatorData[54].toInt() and 0xff)
        return authenticatorData.copyOfRange(55, 55 + credentialIdLength)
    }

    override fun onDestroy() {
        super.onDestroy()
        yubiKitManager.stopUsbDiscovery()
    }

    private fun appendLine(line: String) {
        runOnUiThread { logView.append(line + "\n") }
    }
}
