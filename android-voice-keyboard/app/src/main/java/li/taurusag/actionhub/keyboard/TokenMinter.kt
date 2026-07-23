package li.taurusag.actionhub.keyboard

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject

object TokenMinter {
    private val httpClient = OkHttpClient()

    fun mint(apiKey: String): String {
        val request = Request.Builder()
            .url("https://api.elevenlabs.io/v1/single-use-token/realtime_scribe")
            .header("xi-api-key", apiKey)
            .post(ByteArray(0).toRequestBody(null))
            .build()
        httpClient.newCall(request).execute().use { response ->
            val body = response.body?.string() ?: ""
            if (!response.isSuccessful) {
                throw IllegalStateException("token mint failed: HTTP ${response.code} $body")
            }
            return JSONObject(body).getString("token")
        }
    }
}
