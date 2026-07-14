package li.taurusag.actionhub.viewer

import android.app.Activity
import com.yubico.yubikit.android.YubiKitManager
import com.yubico.yubikit.android.transport.usb.UsbConfiguration
import com.yubico.yubikit.android.transport.usb.UsbYubiKeyDevice
import com.yubico.yubikit.core.fido.FidoConnection
import com.yubico.yubikit.fido.ctap.Ctap2Session

class SignedAssertion(val authenticatorData: ByteArray, val signature: ByteArray) {
    val userVerified: Boolean
        get() = (authenticatorData[32].toInt() and 0x04) != 0
}

class YubiKeyGate(activity: Activity) {
    private val yubiKitManager = YubiKitManager(activity)
    private var attachedDevice: UsbYubiKeyDevice? = null

    var onDeviceChange: ((Boolean) -> Unit)? = null

    fun startDiscovery() {
        yubiKitManager.startUsbDiscovery(UsbConfiguration()) { device ->
            attachedDevice = device
            onDeviceChange?.invoke(true)
        }
    }

    fun stopDiscovery() {
        yubiKitManager.stopUsbDiscovery()
    }

    fun createCredential(onResult: (ByteArray?, String) -> Unit) {
        val device = attachedDevice
        if (device == null) {
            onResult(null, "no yubikey attached")
            return
        }
        device.requestConnection(FidoConnection::class.java) { result ->
            try {
                val session = Ctap2Session(result.value)
                val credential = session.makeCredential(
                    ByteArray(32),
                    mapOf("id" to RELYING_PARTY_ID, "name" to "ActionHub"),
                    mapOf("id" to ByteArray(16) { 7 }, "name" to "viewer", "displayName" to "viewer"),
                    listOf(mapOf("type" to "public-key", "alg" to -7)),
                    null,
                    null,
                    mapOf("uv" to true),
                    null,
                    null,
                    null,
                    null,
                )
                onResult(credential.authenticatorData, "credential created, touch accepted")
            } catch (credentialError: Exception) {
                onResult(null, "credential creation failed: $credentialError")
            }
        }
    }

    fun sign(credentialId: ByteArray, clientDataHash: ByteArray, onResult: (SignedAssertion?, String) -> Unit) {
        val device = attachedDevice
        if (device == null) {
            onResult(null, "no yubikey attached")
            return
        }
        device.requestConnection(FidoConnection::class.java) { result ->
            try {
                val session = Ctap2Session(result.value)
                val assertion = session.getAssertions(
                    RELYING_PARTY_ID,
                    clientDataHash,
                    listOf(mapOf("type" to "public-key", "id" to credentialId)),
                    null,
                    mapOf("uv" to true),
                    null,
                    null,
                    null,
                ).first()
                onResult(SignedAssertion(assertion.authenticatorData, assertion.signature), "signed")
            } catch (signError: Exception) {
                onResult(null, "signing failed: $signError")
            }
        }
    }

    companion object {
        const val RELYING_PARTY_ID = "actionhub"

        fun extractCredentialId(authenticatorData: ByteArray): ByteArray {
            val credentialIdLength = ((authenticatorData[53].toInt() and 0xff) shl 8) or (authenticatorData[54].toInt() and 0xff)
            return authenticatorData.copyOfRange(55, 55 + credentialIdLength)
        }
    }
}
