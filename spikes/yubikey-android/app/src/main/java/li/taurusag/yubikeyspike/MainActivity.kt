package li.taurusag.yubikeyspike

import android.app.Activity
import android.os.Bundle
import android.widget.ScrollView
import android.widget.TextView
import com.yubico.yubikit.android.YubiKitManager
import com.yubico.yubikit.android.transport.usb.UsbConfiguration
import com.yubico.yubikit.core.fido.FidoConnection
import com.yubico.yubikit.fido.ctap.Ctap2Session

class MainActivity : Activity() {
    private lateinit var logView: TextView
    private lateinit var yubiKitManager: YubiKitManager

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        logView = TextView(this)
        logView.setPadding(32, 64, 32, 64)
        logView.setTextIsSelectable(true)
        val scrollView = ScrollView(this)
        scrollView.addView(logView)
        setContentView(scrollView)
        appendLine("plug in the YubiKey Bio via USB-C")
        yubiKitManager = YubiKitManager(this)
        yubiKitManager.startUsbDiscovery(UsbConfiguration()) { device ->
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

    override fun onDestroy() {
        super.onDestroy()
        yubiKitManager.stopUsbDiscovery()
    }

    private fun appendLine(line: String) {
        runOnUiThread { logView.append(line + "\n") }
    }
}
