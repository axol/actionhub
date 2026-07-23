package li.taurusag.actionhub.keyboard

import android.content.Context
import com.yubico.yubikit.android.YubiKitManager
import com.yubico.yubikit.android.transport.usb.UsbConfiguration
import com.yubico.yubikit.android.transport.usb.UsbYubiKeyDevice

class YubiKeyPort(context: Context) {
    private val yubiKitManager = YubiKitManager(context)

    var attachedDevice: UsbYubiKeyDevice? = null
        private set
    var onDeviceChange: ((Boolean) -> Unit)? = null

    fun startDiscovery() {
        yubiKitManager.startUsbDiscovery(UsbConfiguration()) { device ->
            attachedDevice = device
            onDeviceChange?.invoke(true)
        }
    }

    fun stopDiscovery() {
        yubiKitManager.stopUsbDiscovery()
        attachedDevice = null
    }
}
