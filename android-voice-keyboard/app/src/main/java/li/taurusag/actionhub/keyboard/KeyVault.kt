package li.taurusag.actionhub.keyboard

import android.content.Context
import android.util.Base64
import com.yubico.yubikit.android.transport.usb.UsbYubiKeyDevice
import com.yubico.yubikit.core.fido.FidoConnection
import com.yubico.yubikit.fido.client.BasicWebAuthnClient
import com.yubico.yubikit.fido.client.extensions.HmacSecretExtension
import com.yubico.yubikit.fido.ctap.Ctap2Session
import com.yubico.yubikit.fido.webauthn.AuthenticatorSelectionCriteria
import com.yubico.yubikit.fido.webauthn.Extensions
import com.yubico.yubikit.fido.webauthn.PublicKeyCredentialCreationOptions
import com.yubico.yubikit.fido.webauthn.PublicKeyCredentialDescriptor
import com.yubico.yubikit.fido.webauthn.PublicKeyCredentialParameters
import com.yubico.yubikit.fido.webauthn.PublicKeyCredentialRequestOptions
import com.yubico.yubikit.fido.webauthn.PublicKeyCredentialRpEntity
import com.yubico.yubikit.fido.webauthn.PublicKeyCredentialUserEntity
import com.yubico.yubikit.fido.webauthn.ResidentKeyRequirement
import com.yubico.yubikit.fido.webauthn.SerializationType
import com.yubico.yubikit.fido.webauthn.UserVerificationRequirement
import java.io.File
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import org.json.JSONObject

class KeyVault(private val context: Context) {
    fun isEnrolled(): Boolean = vaultFile().exists()

    fun credentialId(): ByteArray? {
        if (!isEnrolled()) return null
        val vault = JSONObject(vaultFile().readText())
        return decodeBase64(vault.getString("credential_id"))
    }

    fun enroll(device: UsbYubiKeyDevice, apiKey: String, onResult: (Boolean, String) -> Unit) {
        device.requestConnection(FidoConnection::class.java) { connectionResult ->
            try {
                val session = Ctap2Session(connectionResult.value)
                val credentialId = createCredential(session)
                val salt = randomBytes(32)
                val wrappingKey = deriveWrappingKey(session, credentialId, salt)
                val initializationVector = randomBytes(12)
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(
                    Cipher.ENCRYPT_MODE,
                    SecretKeySpec(wrappingKey, "AES"),
                    GCMParameterSpec(128, initializationVector),
                )
                val ciphertext = cipher.doFinal(apiKey.toByteArray(Charsets.UTF_8))
                wrappingKey.fill(0)
                val vault = JSONObject()
                    .put("credential_id", encodeBase64(credentialId))
                    .put("salt", encodeBase64(salt))
                    .put("initialization_vector", encodeBase64(initializationVector))
                    .put("ciphertext", encodeBase64(ciphertext))
                vaultFile().writeText(vault.toString())
                onResult(true, "api key wrapped and stored")
            } catch (enrollmentError: Exception) {
                onResult(false, "enrollment failed: ${describeFidoError(enrollmentError)}")
            }
        }
    }

    fun unwrap(device: UsbYubiKeyDevice, onResult: (String?, String) -> Unit) {
        if (!isEnrolled()) {
            onResult(null, "vault empty, run enrollment first")
            return
        }
        device.requestConnection(FidoConnection::class.java) { connectionResult ->
            try {
                val session = Ctap2Session(connectionResult.value)
                val vault = JSONObject(vaultFile().readText())
                val wrappingKey = deriveWrappingKey(
                    session,
                    decodeBase64(vault.getString("credential_id")),
                    decodeBase64(vault.getString("salt")),
                )
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(
                    Cipher.DECRYPT_MODE,
                    SecretKeySpec(wrappingKey, "AES"),
                    GCMParameterSpec(128, decodeBase64(vault.getString("initialization_vector"))),
                )
                val apiKeyBytes = cipher.doFinal(decodeBase64(vault.getString("ciphertext")))
                wrappingKey.fill(0)
                onResult(String(apiKeyBytes, Charsets.UTF_8), "unwrapped")
                apiKeyBytes.fill(0)
            } catch (unwrapError: Exception) {
                onResult(null, "unwrap failed: ${describeFidoError(unwrapError)}")
            }
        }
    }

    private fun createCredential(session: Ctap2Session): ByteArray {
        val client = BasicWebAuthnClient(session, listOf(HmacSecretExtension(true)))
        val challenge = randomBytes(32)
        val creationOptions = PublicKeyCredentialCreationOptions(
            PublicKeyCredentialRpEntity("ActionHub", RELYING_PARTY_ID),
            PublicKeyCredentialUserEntity("keyboard", ByteArray(16) { 11 }, "keyboard"),
            challenge,
            listOf(PublicKeyCredentialParameters("public-key", -7)),
            null,
            null,
            AuthenticatorSelectionCriteria(
                null,
                ResidentKeyRequirement.DISCOURAGED,
                UserVerificationRequirement.REQUIRED,
            ),
            null,
            Extensions.fromMap(mapOf("hmacCreateSecret" to true)),
        )
        val credential = client.makeCredential(
            clientDataJson("webauthn.create", challenge),
            creationOptions,
            RELYING_PARTY_ID,
            null,
            null,
            null,
        )
        return credential.rawId
    }

    private fun deriveWrappingKey(session: Ctap2Session, credentialId: ByteArray, salt: ByteArray): ByteArray {
        val client = BasicWebAuthnClient(session, listOf(HmacSecretExtension(true)))
        val challenge = randomBytes(32)
        val requestOptions = PublicKeyCredentialRequestOptions(
            challenge,
            null,
            RELYING_PARTY_ID,
            listOf(PublicKeyCredentialDescriptor("public-key", credentialId)),
            UserVerificationRequirement.REQUIRED,
            Extensions.fromMap(mapOf("hmacGetSecret" to mapOf("salt1" to encodeBase64(salt)))),
        )
        val credential = client.getAssertion(
            clientDataJson("webauthn.get", challenge),
            requestOptions,
            RELYING_PARTY_ID,
            null,
            null,
        )
        val extensionResults = credential.clientExtensionResults
            ?: throw IllegalStateException("no client extension results")
        val hmacOutputs = extensionResults.toMap(SerializationType.CBOR)["hmacGetSecret"] as? Map<*, *>
            ?: throw IllegalStateException("hmac-secret output missing, key may lack support")
        return hmacOutputs["output1"] as ByteArray
    }

    private fun vaultFile(): File = File(context.filesDir, "vault.json")

    companion object {
        const val RELYING_PARTY_ID = "actionhub"

        fun describeFidoError(error: Throwable): String {
            var cause: Throwable? = error
            while (cause != null) {
                if (cause is com.yubico.yubikit.core.fido.CtapException) {
                    return when (cause.ctapError) {
                        com.yubico.yubikit.core.fido.CtapException.ERR_UV_INVALID -> "fingerprint not recognized"
                        com.yubico.yubikit.core.fido.CtapException.ERR_UV_BLOCKED -> "fingerprint blocked — reinsert the key"
                        com.yubico.yubikit.core.fido.CtapException.ERR_OPERATION_DENIED -> "denied on the key"
                        com.yubico.yubikit.core.fido.CtapException.ERR_USER_ACTION_TIMEOUT,
                        com.yubico.yubikit.core.fido.CtapException.ERR_ACTION_TIMEOUT,
                        -> "touch timed out"
                        else -> "ctap error 0x%02x".format(cause.ctapError)
                    }
                }
                cause = cause.cause
            }
            return error.toString()
        }

        fun clientDataJson(type: String, challenge: ByteArray): ByteArray = JSONObject()
            .put("type", type)
            .put("challenge", encodeBase64(challenge))
            .put("origin", "android:app:li.taurusag.actionhub.keyboard")
            .put("crossOrigin", false)
            .toString()
            .toByteArray(Charsets.UTF_8)

        fun encodeBase64(bytes: ByteArray): String =
            Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)

        fun decodeBase64(text: String): ByteArray =
            Base64.decode(text, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)

        fun randomBytes(count: Int): ByteArray = ByteArray(count).also { SecureRandom().nextBytes(it) }
    }
}
