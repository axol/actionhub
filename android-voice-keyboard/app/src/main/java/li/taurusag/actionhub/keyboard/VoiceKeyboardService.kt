package li.taurusag.actionhub.keyboard

import android.Manifest
import android.animation.ObjectAnimator
import android.animation.ValueAnimator
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.StateListDrawable
import android.inputmethodservice.InputMethodService
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.TextPaint
import android.text.method.LinkMovementMethod
import android.text.style.BackgroundColorSpan
import android.text.style.ClickableSpan
import android.text.style.ForegroundColorSpan
import android.text.style.StrikethroughSpan
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

class VoiceKeyboardService : InputMethodService() {
    private class Token(var text: String, var struck: Boolean = false)

    private class Segment(text: String) {
        val tokens: MutableList<Token> =
            text.split(WHITESPACE).filter { it.isNotBlank() }.map { Token(it) }.toMutableList()
        var struck = false

        fun visibleText(): String =
            tokens.filterNot { token -> token.struck }.joinToString(" ") { token -> token.text }

        companion object {
            val WHITESPACE = Regex("\\s+")
        }
    }

    private class ActionView(val frame: FrameLayout, val icon: ImageView, val label: TextView)

    private enum class KeyboardState { IDLE, RECORDING, REVIEW }

    private enum class UnlockPhase { NONE, NEED_KEY, TOUCH }

    private enum class EditMode { NONE, SUGGEST, TYPE }

    private enum class ShiftState { OFF, SHIFT, CAPS }

    private lateinit var keyVault: KeyVault
    private lateinit var yubiKeyPort: YubiKeyPort
    private lateinit var correctionStore: CorrectionStore
    private lateinit var rootView: LinearLayout
    private lateinit var transcriptScroll: ScrollView
    private lateinit var segmentsContainer: LinearLayout
    private lateinit var partialView: TextView
    private lateinit var messageView: TextView
    private lateinit var unlockOverlay: LinearLayout
    private lateinit var unlockIcon: ImageView
    private lateinit var unlockCaption: TextView
    private lateinit var suggestionStrip: HorizontalScrollView
    private lateinit var suggestionRow: LinearLayout
    private lateinit var typingPad: LinearLayout
    private lateinit var typingPreview: TextView
    private lateinit var morphAction: ActionView
    private lateinit var speakMoreAction: ActionView
    private lateinit var discardAction: ActionView
    private var unlockPulse: ObjectAnimator? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val segments = mutableListOf<Segment>()
    private var partialText = ""
    private var unlockPhase = UnlockPhase.NONE
    private var unlocking = false
    private var unlockRetryCaption: String? = null
    private var pressStartedTake = false
    private var pressDownAt = 0L
    private var editMode = EditMode.NONE
    private var selectedSegment: Segment? = null
    private var selectionStart = -1
    private var selectionEnd = -1
    private val typedText = StringBuilder()
    private var shiftState = ShiftState.OFF
    private var shiftKey: TextView? = null
    private val letterKeys = mutableListOf<Pair<TextView, String>>()
    private var accentPopup: android.widget.PopupWindow? = null
    private var cachedApiKey: String? = null
    private var cachedApiKeyAt = 0L
    private var everUnlocked = false
    private val idleCloseRunnable = Runnable {
        if (!audioCapture.isCapturing) scribeSocket.close()
    }
    private val clearMessageRunnable = Runnable { if (::messageView.isInitialized) messageView.text = "" }

    private val audioCapture: AudioCapture = AudioCapture { audioChunk -> scribeSocket.sendAudio(audioChunk) }

    private val scribeSocket: ScribeSocket = ScribeSocket(
        onPartial = { text ->
            mainHandler.post {
                if (!audioCapture.isCapturing) return@post
                partialText = text
                render()
            }
        },
        onCommitted = { },
        onStatus = { status -> mainHandler.post { showMessage(status) } },
        onClosed = {
            mainHandler.post {
                val wasCapturing = audioCapture.isCapturing
                audioCapture.stop()
                val freshKey = cachedApiKeyIfFresh()
                if (wasCapturing && freshKey != null && !unlocking) {
                    showMessage("scribe reconnecting")
                    refreshSession(freshKey)
                } else {
                    render()
                }
            }
        },
    )

    override fun onCreate() {
        super.onCreate()
        keyVault = KeyVault(this)
        correctionStore = CorrectionStore(this)
        yubiKeyPort = YubiKeyPort(this)
        yubiKeyPort.onDeviceChange = { attached ->
            mainHandler.post {
                if (attached && unlockPhase == UnlockPhase.NEED_KEY) {
                    yubiKeyPort.attachedDevice?.let { device -> startUnlock(device) }
                }
            }
        }
        yubiKeyPort.startDiscovery()
    }

    override fun onDestroy() {
        endSession()
        yubiKeyPort.stopDiscovery()
        super.onDestroy()
    }

    override fun onCreateInputView(): View = buildLayout()

    override fun onFinishInputView(finishingInput: Boolean) {
        unlockPhase = UnlockPhase.NONE
        clearSelection()
        accentPopup?.dismiss()
        accentPopup = null
        if (audioCapture.isCapturing) endTake()
        mainHandler.removeCallbacks(idleCloseRunnable)
        mainHandler.postDelayed(idleCloseRunnable, SOCKET_IDLE_MILLISECONDS)
        super.onFinishInputView(finishingInput)
    }

    private fun currentState(): KeyboardState = when {
        audioCapture.isCapturing -> KeyboardState.RECORDING
        segments.isNotEmpty() || partialText.isNotBlank() -> KeyboardState.REVIEW
        else -> KeyboardState.IDLE
    }

    private fun beginTake() {
        if (audioCapture.isCapturing || unlocking) return
        clearSelection()
        if (!keyVault.isEnrolled()) {
            showMessage("no key yet — open the app")
            return
        }
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            showMessage("allow the microphone in the app")
            return
        }
        if (scribeSocket.isOpen) {
            mainHandler.removeCallbacks(idleCloseRunnable)
            startCapture()
            render()
            return
        }
        val freshKey = cachedApiKeyIfFresh()
        if (freshKey != null) {
            refreshSession(freshKey)
            return
        }
        val device = yubiKeyPort.attachedDevice
        if (device == null) {
            unlockPhase = UnlockPhase.NEED_KEY
            render()
            return
        }
        startUnlock(device)
    }

    private fun cachedApiKeyIfFresh(): String? =
        cachedApiKey?.takeIf { SystemClock.elapsedRealtime() - cachedApiKeyAt < KEY_CACHE_MILLISECONDS }

    private fun refreshSession(apiKey: String) {
        unlocking = true
        showMessage("refreshing scribe access")
        Thread {
            try {
                val token = TokenMinter.mint(apiKey)
                mainHandler.post {
                    unlocking = false
                    scribeSocket.connect(token)
                    startCapture()
                    render()
                }
            } catch (mintError: Exception) {
                mainHandler.post {
                    unlocking = false
                    cachedApiKey = null
                    showMessage("refresh failed: ${mintError.message}")
                    render()
                }
            }
        }.start()
    }

    private fun startUnlock(
        device: com.yubico.yubikit.android.transport.usb.UsbYubiKeyDevice,
        retriesLeft: Int = 2,
        retryCaption: String? = null,
    ) {
        if (unlocking) return
        unlocking = true
        unlockPhase = UnlockPhase.TOUCH
        unlockRetryCaption = retryCaption
        render()
        keyVault.unwrap(device) { apiKey, message ->
            if (apiKey == null) {
                mainHandler.post {
                    unlocking = false
                    val attachedDevice = yubiKeyPort.attachedDevice
                    val retryable = message.contains("fingerprint not recognized") || message.contains("touch timed out")
                    if (retryable && retriesLeft > 0 && attachedDevice != null) {
                        startUnlock(attachedDevice, retriesLeft - 1, "$message — touch again")
                    } else {
                        unlockPhase = UnlockPhase.NONE
                        unlockRetryCaption = null
                        showMessage(message)
                        render()
                    }
                }
                return@unwrap
            }
            mainHandler.post {
                unlocking = false
                unlockPhase = UnlockPhase.NONE
                cachedApiKey = apiKey
                cachedApiKeyAt = SystemClock.elapsedRealtime()
                everUnlocked = true
                render()
                refreshSession(apiKey)
            }
        }
    }

    private fun startCapture() {
        partialText = ""
        audioCapture.start()
    }

    private fun endTake() {
        if (!audioCapture.isCapturing) return
        audioCapture.stop()
        scribeSocket.sendAudio(ByteArray(320), commit = true)
        if (partialText.isNotBlank()) {
            segments.add(Segment(partialText.trim()))
            partialText = ""
        }
        render()
    }

    private fun endSession() {
        audioCapture.stop()
        scribeSocket.close()
        if (partialText.isNotBlank()) {
            segments.add(Segment(partialText.trim()))
            partialText = ""
        }
        if (::rootView.isInitialized) render()
    }

    private fun commit() {
        clearSelection()
        val assembled = segments.filterNot { segment -> segment.struck }
            .map { segment -> segment.visibleText() }
            .filter { text -> text.isNotBlank() }
            .joinToString(" ")
            .trim()
        if (assembled.isEmpty()) {
            showMessage("everything struck — discard to clear")
            return
        }
        currentInputConnection?.commitText("$assembled ", 1)
        segments.clear()
        partialText = ""
        render()
    }

    private fun discard() {
        clearSelection()
        segments.clear()
        partialText = ""
        render()
    }

    private fun onTokenTap(segment: Segment, tokenIndex: Int) {
        if (editMode == EditMode.TYPE) return
        if (selectedSegment === segment && tokenIndex in selectionStart..selectionEnd) {
            clearSelection()
        } else if (selectedSegment === segment && selectionStart >= 0) {
            selectionStart = minOf(selectionStart, tokenIndex)
            selectionEnd = maxOf(selectionEnd, tokenIndex)
        } else {
            selectedSegment = segment
            selectionStart = tokenIndex
            selectionEnd = tokenIndex
            editMode = EditMode.SUGGEST
        }
        render()
    }

    private fun clearSelection() {
        selectedSegment = null
        selectionStart = -1
        selectionEnd = -1
        editMode = EditMode.NONE
        typedText.clear()
        setShiftState(ShiftState.OFF)
    }

    private fun heardKey(segment: Segment): String =
        (selectionStart..selectionEnd).joinToString(" ") { tokenIndex ->
            normalizeToken(segment.tokens[tokenIndex].text)
        }

    private fun normalizeToken(text: String): String =
        text.trim { character -> !character.isLetterOrDigit() }.lowercase()

    private fun applyReplacement(replacementRaw: String) {
        val segment = selectedSegment ?: return
        val replacement = replacementRaw.trim()
        if (replacement.isEmpty()) {
            clearSelection()
            render()
            return
        }
        val heard = heardKey(segment)
        val trailingPunctuation = segment.tokens[selectionEnd].text.takeLastWhile { it in ".,!?;:" }
        val finalText =
            if (trailingPunctuation.isNotEmpty() && replacement.last() !in ".,!?;:") replacement + trailingPunctuation
            else replacement
        val newTokens = finalText.split(Segment.WHITESPACE).filter { it.isNotBlank() }.map { Token(it) }
        repeat(selectionEnd - selectionStart + 1) { segment.tokens.removeAt(selectionStart) }
        segment.tokens.addAll(selectionStart, newTokens)
        correctionStore.recordCorrection(heard, replacement)
        clearSelection()
        render()
    }

    private fun toggleStrikeSelection() {
        val segment = selectedSegment ?: return
        val range = selectionStart..selectionEnd
        val anyUnstruck = range.any { tokenIndex -> !segment.tokens[tokenIndex].struck }
        range.forEach { tokenIndex -> segment.tokens[tokenIndex].struck = anyUnstruck }
        clearSelection()
        render()
    }

    private fun onMorphTouch(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                morphAction.frame.isPressed = true
                pressDownAt = SystemClock.uptimeMillis()
                when (currentState()) {
                    KeyboardState.IDLE -> {
                        pressStartedTake = true
                        beginTake()
                    }
                    KeyboardState.RECORDING, KeyboardState.REVIEW -> pressStartedTake = false
                }
            }
            MotionEvent.ACTION_UP -> {
                morphAction.frame.isPressed = false
                val heldMilliseconds = SystemClock.uptimeMillis() - pressDownAt
                when (currentState()) {
                    KeyboardState.RECORDING ->
                        if (!pressStartedTake || heldMilliseconds >= HOLD_THRESHOLD_MILLISECONDS) endTake()
                    KeyboardState.REVIEW -> commit()
                    KeyboardState.IDLE -> {}
                }
                pressStartedTake = false
            }
            MotionEvent.ACTION_CANCEL -> {
                morphAction.frame.isPressed = false
                if (pressStartedTake && audioCapture.isCapturing) endTake()
                pressStartedTake = false
            }
        }
        return true
    }

    private fun render() {
        if (!::rootView.isInitialized) return
        val state = currentState()

        segmentsContainer.removeAllViews()
        segments.forEach { segment -> segmentsContainer.addView(buildSegmentRow(segment)) }
        partialView.text = partialText
        partialView.visibility = if (partialText.isBlank()) View.GONE else View.VISIBLE
        transcriptScroll.visibility =
            if (unlockPhase != UnlockPhase.NONE || (segments.isEmpty() && partialText.isBlank())) View.GONE else View.VISIBLE
        transcriptScroll.post { transcriptScroll.fullScroll(ScrollView.FOCUS_DOWN) }

        renderUnlockOverlay()
        renderEditSurface()

        when (state) {
            KeyboardState.IDLE -> styleMorph(iconResource = R.drawable.ic_mic, labelText = null, filled = false)
            KeyboardState.RECORDING -> styleMorph(iconResource = R.drawable.ic_stop, labelText = null, filled = true)
            KeyboardState.REVIEW -> styleMorph(iconResource = R.drawable.ic_check, labelText = null, filled = true)
        }
        speakMoreAction.frame.visibility = if (state == KeyboardState.REVIEW) View.VISIBLE else View.GONE
        discardAction.frame.visibility = if (state == KeyboardState.REVIEW) View.VISIBLE else View.GONE

        rootView.requestLayout()
    }

    private fun renderEditSurface() {
        val segment = selectedSegment
        if (editMode == EditMode.NONE || segment == null) {
            suggestionStrip.visibility = View.GONE
            typingPad.visibility = View.GONE
            return
        }
        if (editMode == EditMode.SUGGEST) {
            typingPad.visibility = View.GONE
            suggestionStrip.visibility = View.VISIBLE
            suggestionRow.removeAllViews()
            correctionStore.suggestionsFor(heardKey(segment)).forEach { suggestion ->
                suggestionRow.addView(buildChip(suggestion, filled = true) { applyReplacement(suggestion) }, chipParams())
            }
            suggestionRow.addView(buildChip("type…", filled = false) {
                editMode = EditMode.TYPE
                typedText.clear()
                setShiftState(ShiftState.OFF)
                render()
            }, chipParams())
            val range = selectionStart..selectionEnd
            val anyUnstruck = range.any { tokenIndex -> !segment.tokens[tokenIndex].struck }
            suggestionRow.addView(
                buildChip(if (anyUnstruck) "strike" else "restore", filled = false) { toggleStrikeSelection() },
                chipParams(),
            )
        } else {
            suggestionStrip.visibility = View.GONE
            typingPad.visibility = View.VISIBLE
            typingPreview.text = if (typedText.isEmpty()) "…" else typedText.toString()
        }
    }

    private fun renderUnlockOverlay() {
        if (unlockPhase == UnlockPhase.NONE) {
            unlockOverlay.visibility = View.GONE
            unlockPulse?.cancel()
            unlockPulse = null
            unlockIcon.alpha = 1f
            return
        }
        unlockOverlay.visibility = View.VISIBLE
        when (unlockPhase) {
            UnlockPhase.NEED_KEY -> {
                unlockIcon.setImageResource(R.drawable.ic_key)
                unlockCaption.text = "plug in the yubikey"
            }
            UnlockPhase.TOUCH -> {
                unlockIcon.setImageResource(R.drawable.ic_fingerprint)
                unlockCaption.text = unlockRetryCaption
                    ?: if (everUnlocked) "scribe access expired — touch the yubikey" else "touch the yubikey"
            }
            UnlockPhase.NONE -> {}
        }
        if (unlockPulse == null) {
            unlockPulse = ObjectAnimator.ofFloat(unlockIcon, "alpha", 1f, 0.3f).also { pulse ->
                pulse.duration = 800
                pulse.repeatMode = ValueAnimator.REVERSE
                pulse.repeatCount = ValueAnimator.INFINITE
                pulse.start()
            }
        }
    }

    private fun showMessage(message: String, sticky: Boolean = false) {
        if (!::messageView.isInitialized) return
        messageView.text = message
        mainHandler.removeCallbacks(clearMessageRunnable)
        if (!sticky && message.isNotEmpty()) mainHandler.postDelayed(clearMessageRunnable, 5000)
    }

    private fun buildSegmentRow(segment: Segment): LinearLayout {
        val strikeButton = ImageView(this)
        strikeButton.setImageResource(R.drawable.ic_x)
        strikeButton.imageTintList = ColorStateList.valueOf(INK_FAINT)
        strikeButton.setPadding(dp(6), dp(6), dp(10), dp(6))
        strikeButton.setOnClickListener {
            segment.struck = !segment.struck
            clearSelection()
            render()
        }

        val textView = TextView(this)
        textView.textSize = 19f
        textView.setLineSpacing(0f, 1.15f)
        textView.setPadding(0, dp(7), 0, dp(7))
        textView.movementMethod = LinkMovementMethod.getInstance()
        textView.highlightColor = Color.TRANSPARENT
        textView.text = buildSegmentSpannable(segment)
        textView.layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)

        val contentRow = LinearLayout(this)
        contentRow.orientation = LinearLayout.HORIZONTAL
        contentRow.gravity = Gravity.CENTER_VERTICAL
        contentRow.addView(strikeButton, LinearLayout.LayoutParams(dp(38), dp(38)))
        contentRow.addView(textView)

        val ruledLine = View(this)
        ruledLine.setBackgroundColor(RULE)

        val row = LinearLayout(this)
        row.orientation = LinearLayout.VERTICAL
        row.addView(contentRow)
        row.addView(ruledLine, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(1)))
        return row
    }

    private fun buildSegmentSpannable(segment: Segment): SpannableStringBuilder {
        val builder = SpannableStringBuilder()
        segment.tokens.forEachIndexed { tokenIndex, token ->
            if (tokenIndex > 0) builder.append(" ")
            val start = builder.length
            builder.append(token.text)
            val end = builder.length
            builder.setSpan(
                object : ClickableSpan() {
                    override fun onClick(widget: View) = onTokenTap(segment, tokenIndex)
                    override fun updateDrawState(paint: TextPaint) {
                        paint.isUnderlineText = false
                    }
                },
                start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE,
            )
            val selected = selectedSegment === segment && tokenIndex in selectionStart..selectionEnd
            val struck = token.struck || segment.struck
            if (selected) {
                builder.setSpan(BackgroundColorSpan(INK), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                builder.setSpan(ForegroundColorSpan(PAPER), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            } else {
                builder.setSpan(ForegroundColorSpan(if (struck) INK_FAINT else INK), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            if (struck) builder.setSpan(StrikethroughSpan(), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        return builder
    }

    private fun buildLayout(): View {
        rootView = LinearLayout(this)
        rootView.orientation = LinearLayout.VERTICAL
        rootView.setBackgroundColor(PAPER)
        rootView.setPadding(dp(14), dp(6), dp(14), dp(6))

        segmentsContainer = LinearLayout(this)
        segmentsContainer.orientation = LinearLayout.VERTICAL

        partialView = TextView(this)
        partialView.textSize = 17f
        partialView.setTextColor(INK_SOFT)
        partialView.setTypeface(null, Typeface.ITALIC)
        partialView.setPadding(0, dp(6), 0, dp(4))

        val transcriptColumn = LinearLayout(this)
        transcriptColumn.orientation = LinearLayout.VERTICAL
        transcriptColumn.addView(segmentsContainer)
        transcriptColumn.addView(partialView)

        transcriptScroll = MaxHeightScrollView(this, dp(280))
        transcriptScroll.addView(transcriptColumn)
        transcriptScroll.visibility = View.GONE
        rootView.addView(
            transcriptScroll,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT),
        )

        unlockIcon = ImageView(this)
        unlockIcon.imageTintList = ColorStateList.valueOf(INK)
        unlockCaption = TextView(this)
        unlockCaption.textSize = 13f
        unlockCaption.setTextColor(INK_SOFT)
        unlockCaption.typeface = Typeface.MONOSPACE
        unlockCaption.gravity = Gravity.CENTER
        unlockCaption.setPadding(0, dp(10), 0, 0)
        unlockOverlay = LinearLayout(this)
        unlockOverlay.orientation = LinearLayout.VERTICAL
        unlockOverlay.gravity = Gravity.CENTER
        unlockOverlay.visibility = View.GONE
        unlockOverlay.setOnClickListener {
            if (!unlocking) {
                unlockPhase = UnlockPhase.NONE
                render()
            }
        }
        unlockOverlay.addView(unlockIcon, LinearLayout.LayoutParams(dp(56), dp(56)))
        unlockOverlay.addView(unlockCaption)
        rootView.addView(
            unlockOverlay,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(132)),
        )

        suggestionRow = LinearLayout(this)
        suggestionRow.orientation = LinearLayout.HORIZONTAL
        suggestionStrip = HorizontalScrollView(this)
        suggestionStrip.isHorizontalScrollBarEnabled = false
        suggestionStrip.addView(suggestionRow)
        suggestionStrip.visibility = View.GONE
        rootView.addView(
            suggestionStrip,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(46)),
        )

        typingPad = buildTypingPad()
        typingPad.visibility = View.GONE
        rootView.addView(
            typingPad,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT),
        )

        val actionRow = LinearLayout(this)
        actionRow.orientation = LinearLayout.HORIZONTAL
        actionRow.gravity = Gravity.CENTER_VERTICAL

        discardAction = buildAction(R.drawable.ic_x, labelText = null, minimumWidthDp = 52)
        discardAction.frame.setOnClickListener { discard() }
        discardAction.frame.visibility = View.GONE
        actionRow.addView(discardAction.frame, actionParams())

        messageView = TextView(this)
        messageView.textSize = 12f
        messageView.setTextColor(INK_SOFT)
        messageView.typeface = Typeface.MONOSPACE
        messageView.setPadding(dp(8), 0, dp(8), 0)
        actionRow.addView(messageView, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))

        speakMoreAction = buildAction(R.drawable.ic_mic, labelText = null, minimumWidthDp = 64)
        speakMoreAction.frame.setOnClickListener { beginTake() }
        speakMoreAction.frame.visibility = View.GONE
        actionRow.addView(speakMoreAction.frame, actionParams())

        morphAction = buildAction(R.drawable.ic_mic, labelText = null, minimumWidthDp = 128)
        morphAction.frame.setOnTouchListener { _, event -> onMorphTouch(event) }
        actionRow.addView(morphAction.frame, actionParams())

        rootView.addView(
            actionRow,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(52)),
        )

        render()
        return rootView
    }

    private fun buildTypingPad(): LinearLayout {
        val pad = LinearLayout(this)
        pad.orientation = LinearLayout.VERTICAL
        letterKeys.clear()

        typingPreview = TextView(this)
        typingPreview.textSize = 20f
        typingPreview.setTextColor(INK)
        typingPreview.typeface = Typeface.MONOSPACE
        typingPreview.gravity = Gravity.CENTER
        typingPreview.setPadding(0, dp(8), 0, dp(8))
        pad.addView(typingPreview, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))

        val letterRows = listOf(
            listOf("q", "w", "e", "r", "t", "y", "u", "i", "o", "p"),
            listOf("a", "s", "d", "f", "g", "h", "j", "k", "l"),
        )
        letterRows.forEach { letters ->
            val keyRow = LinearLayout(this)
            keyRow.orientation = LinearLayout.HORIZONTAL
            letters.forEach { letter -> keyRow.addView(buildLetterKey(letter), keyParams(1f)) }
            pad.addView(keyRow, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(52)))
        }

        val thirdRow = LinearLayout(this)
        thirdRow.orientation = LinearLayout.HORIZONTAL
        shiftKey = buildKey("⇧") { cycleShift() }
        thirdRow.addView(shiftKey, keyParams(1.5f))
        listOf("z", "x", "c", "v", "b", "n", "m").forEach { letter ->
            thirdRow.addView(buildLetterKey(letter), keyParams(1f))
        }
        thirdRow.addView(buildKey("⌫") {
            if (typedText.isNotEmpty()) typedText.deleteCharAt(typedText.length - 1)
            renderEditSurface()
        }, keyParams(1.5f))
        pad.addView(thirdRow, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(52)))

        val bottomRow = LinearLayout(this)
        bottomRow.orientation = LinearLayout.HORIZONTAL
        bottomRow.addView(buildKey("cancel") {
            editMode = EditMode.SUGGEST
            typedText.clear()
            setShiftState(ShiftState.OFF)
            render()
        }, keyParams(2f))
        bottomRow.addView(buildKey("'") { typeCharacter("'") }, keyParams(1f))
        bottomRow.addView(buildKey("space") { typeCharacter(" ") }, keyParams(4f))
        bottomRow.addView(buildKey("-") { typeCharacter("-") }, keyParams(1f))
        bottomRow.addView(buildKey("done") { applyReplacement(typedText.toString()) }, keyParams(2f))
        pad.addView(bottomRow, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(52)))

        return pad
    }

    private fun buildLetterKey(letter: String): TextView {
        val key = buildKey(letter) { typeCharacter(letter) }
        ACCENT_VARIANTS[letter]?.let { variants ->
            key.setOnLongClickListener {
                showAccentPicker(key, letter, variants)
                true
            }
        }
        letterKeys.add(key to letter)
        return key
    }

    private fun showAccentPicker(anchor: View, base: String, variants: List<String>) {
        accentPopup?.dismiss()
        val variantRow = LinearLayout(this)
        variantRow.orientation = LinearLayout.HORIZONTAL
        variantRow.background = inkPane(fill = false)
        variantRow.setPadding(dp(5), dp(5), dp(5), dp(5))
        (listOf(base) + variants).forEach { variant ->
            val shown = shiftedCharacter(variant)
            val variantKey = buildKey(shown) {
                typeCharacter(variant)
                accentPopup?.dismiss()
                accentPopup = null
            }
            val variantParams = LinearLayout.LayoutParams(dp(46), dp(50))
            variantParams.setMargins(dp(2), 0, dp(2), 0)
            variantRow.addView(variantKey, variantParams)
        }
        val popup = android.widget.PopupWindow(
            variantRow,
            ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
        )
        popup.isOutsideTouchable = true
        popup.setBackgroundDrawable(android.graphics.drawable.ColorDrawable(Color.TRANSPARENT))
        accentPopup = popup
        popup.showAsDropDown(anchor, -dp(8), -(anchor.height + dp(62)))
    }

    private fun shiftedCharacter(character: String): String {
        if (shiftState == ShiftState.OFF || character.length != 1 || !character[0].isLetter()) return character
        val uppercase = character.uppercase()
        return if (uppercase.length == 1) uppercase else character
    }

    private fun cycleShift() {
        setShiftState(
            when (shiftState) {
                ShiftState.OFF -> ShiftState.SHIFT
                ShiftState.SHIFT -> ShiftState.CAPS
                ShiftState.CAPS -> ShiftState.OFF
            },
        )
    }

    private fun setShiftState(newState: ShiftState) {
        shiftState = newState
        shiftKey?.let { key ->
            key.text = if (newState == ShiftState.CAPS) "⇪" else "⇧"
            val filled = newState != ShiftState.OFF
            key.setTextColor(labelFace(filled))
            key.background = buttonFace(filled)
        }
        letterKeys.forEach { (key, letter) ->
            key.text = if (shiftState != ShiftState.OFF) letter.uppercase() else letter
        }
    }

    private fun typeCharacter(character: String) {
        typedText.append(shiftedCharacter(character))
        if (shiftState == ShiftState.SHIFT) setShiftState(ShiftState.OFF)
        renderEditSurface()
    }

    private fun buildKey(label: String, onTap: () -> Unit): TextView {
        val key = TextView(this)
        key.text = label
        key.textSize = 18f
        key.gravity = Gravity.CENTER
        key.setTextColor(labelFace(filled = false))
        key.background = buttonFace(filled = false)
        key.isClickable = true
        key.isFocusable = true
        key.setOnClickListener { onTap() }
        return key
    }

    private fun keyParams(weight: Float): LinearLayout.LayoutParams {
        val layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, weight)
        layoutParams.setMargins(dp(2), dp(2), dp(2), dp(2))
        return layoutParams
    }

    private fun buildChip(label: String, filled: Boolean, onTap: () -> Unit): TextView {
        val chip = TextView(this)
        chip.text = label
        chip.textSize = 15f
        chip.gravity = Gravity.CENTER
        chip.setPadding(dp(16), 0, dp(16), 0)
        chip.setTextColor(labelFace(filled))
        chip.background = buttonFace(filled)
        chip.isClickable = true
        chip.setOnClickListener { onTap() }
        return chip
    }

    private fun chipParams(): LinearLayout.LayoutParams {
        val layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.MATCH_PARENT)
        layoutParams.setMargins(dp(3), dp(4), dp(3), dp(4))
        return layoutParams
    }

    private fun actionParams(): LinearLayout.LayoutParams {
        val layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.MATCH_PARENT)
        layoutParams.setMargins(dp(3), dp(4), dp(3), dp(4))
        return layoutParams
    }

    private fun buildAction(iconResource: Int, labelText: String?, minimumWidthDp: Int): ActionView {
        val icon = ImageView(this)
        icon.setImageResource(iconResource)
        icon.isDuplicateParentStateEnabled = true

        val label = TextView(this)
        label.textSize = 16f
        label.isDuplicateParentStateEnabled = true
        label.visibility = View.GONE

        val content = LinearLayout(this)
        content.orientation = LinearLayout.HORIZONTAL
        content.gravity = Gravity.CENTER
        content.isDuplicateParentStateEnabled = true
        content.addView(icon, LinearLayout.LayoutParams(dp(22), dp(22)))
        val labelParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        labelParams.marginStart = dp(8)
        content.addView(label, labelParams)

        val frame = FrameLayout(this)
        frame.minimumWidth = dp(minimumWidthDp)
        frame.isClickable = true
        frame.isFocusable = true
        frame.setPadding(dp(14), 0, dp(14), 0)
        val contentParams = FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        contentParams.gravity = Gravity.CENTER
        frame.addView(content, contentParams)

        val actionView = ActionView(frame, icon, label)
        styleActionView(actionView, filled = false)
        if (labelText != null) {
            label.text = labelText
            label.visibility = View.VISIBLE
        }
        return actionView
    }

    private fun styleMorph(iconResource: Int, labelText: String?, filled: Boolean) {
        morphAction.icon.setImageResource(iconResource)
        if (labelText == null) {
            morphAction.label.visibility = View.GONE
        } else {
            morphAction.label.text = labelText
            morphAction.label.visibility = View.VISIBLE
        }
        styleActionView(morphAction, filled)
    }

    private fun styleActionView(actionView: ActionView, filled: Boolean) {
        actionView.frame.background = buttonFace(filled)
        actionView.icon.imageTintList = labelFace(filled)
        actionView.label.setTextColor(labelFace(filled))
    }

    private fun labelFace(filled: Boolean): ColorStateList {
        val pressedColor = if (filled) INK else PAPER
        val restingColor = if (filled) PAPER else INK
        return ColorStateList(
            arrayOf(intArrayOf(android.R.attr.state_pressed), intArrayOf()),
            intArrayOf(pressedColor, restingColor),
        )
    }

    private fun buttonFace(filled: Boolean): StateListDrawable {
        val face = StateListDrawable()
        face.addState(intArrayOf(android.R.attr.state_pressed), inkPane(fill = !filled))
        face.addState(intArrayOf(), inkPane(fill = filled))
        return face
    }

    private fun inkPane(fill: Boolean): GradientDrawable {
        val pane = GradientDrawable()
        pane.setColor(if (fill) INK else PAPER)
        pane.setStroke(dp(2), INK)
        pane.cornerRadius = dp(10).toFloat()
        return pane
    }

    private class MaxHeightScrollView(context: Context, private val maximumHeight: Int) : ScrollView(context) {
        override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
            super.onMeasure(
                widthMeasureSpec,
                MeasureSpec.makeMeasureSpec(maximumHeight, MeasureSpec.AT_MOST),
            )
        }
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    companion object {
        private const val HOLD_THRESHOLD_MILLISECONDS = 400L
        private const val KEY_CACHE_MILLISECONDS = 12L * 60 * 60 * 1000
        private const val SOCKET_IDLE_MILLISECONDS = 15L * 60 * 1000
        private val ACCENT_VARIANTS = mapOf(
            "a" to listOf("à", "á", "â", "ä", "æ", "ã", "å", "ā"),
            "c" to listOf("ç", "ć", "č"),
            "e" to listOf("è", "é", "ê", "ë", "ē", "ė", "ę"),
            "i" to listOf("î", "ï", "í", "ī", "į", "ì"),
            "l" to listOf("ł"),
            "n" to listOf("ñ", "ń"),
            "o" to listOf("ô", "ö", "ò", "ó", "œ", "ø", "ō", "õ"),
            "s" to listOf("ß", "ś", "š"),
            "u" to listOf("û", "ü", "ù", "ú", "ū"),
            "y" to listOf("ÿ"),
            "z" to listOf("ž", "ź", "ż"),
        )
        private val PAPER = Color.WHITE
        private val INK = Color.BLACK
        private val INK_SOFT = Color.parseColor("#555555")
        private val INK_FAINT = Color.parseColor("#999999")
        private val RULE = Color.parseColor("#DDDDDD")
    }
}
