package li.taurusag.actionhub.keyboard

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder

class AudioCapture(private val onChunk: (ByteArray) -> Unit) {
    private var audioRecord: AudioRecord? = null
    private var captureThread: Thread? = null

    val isCapturing: Boolean
        get() = audioRecord != null

    @SuppressLint("MissingPermission")
    fun start() {
        if (audioRecord != null) return
        val minimumBufferSize = AudioRecord.getMinBufferSize(
            ScribeSocket.SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        val record = AudioRecord(
            MediaRecorder.AudioSource.MIC,
            ScribeSocket.SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            maxOf(minimumBufferSize, CHUNK_BYTES * 4),
        )
        audioRecord = record
        record.startRecording()
        captureThread = Thread {
            val buffer = ByteArray(CHUNK_BYTES)
            while (audioRecord === record) {
                val bytesRead = record.read(buffer, 0, buffer.size)
                if (bytesRead > 0) {
                    onChunk(buffer.copyOf(bytesRead))
                }
            }
        }.also { it.start() }
    }

    fun stop() {
        val record = audioRecord ?: return
        audioRecord = null
        captureThread?.join(500)
        captureThread = null
        record.stop()
        record.release()
    }

    companion object {
        const val CHUNK_BYTES = 3200
    }
}
