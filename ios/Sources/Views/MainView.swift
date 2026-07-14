import SwiftUI

struct MainView: View {
    @EnvironmentObject var phoneController: PhoneController

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                mainPageSettings
                statusHeader
                TranscriptView(transcriptBuffer: phoneController.transcriptBuffer)
                EventLogView(eventLog: phoneController.eventLog)
                controlButtons
            }
            .padding()
            .navigationTitle(phoneController.presetStore.activePreset.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    presetMenu
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        PresetListView(presetStore: phoneController.presetStore, soundLibrary: phoneController.soundLibrary)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
        .onAppear { phoneController.start() }
    }

    private var presetMenu: some View {
        Menu {
            ForEach(phoneController.presetStore.presets) { preset in
                Button {
                    phoneController.presetStore.activatePreset(preset.id)
                } label: {
                    if preset.id == phoneController.presetStore.activePresetId {
                        Label(preset.name, systemImage: "checkmark")
                    } else {
                        Text(preset.name)
                    }
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
    }

    private var mainPageSettings: some View {
        let settings = phoneController.presetStore.activeSettings
        let visibleKeys = phoneController.presetStore.activePreset.mainPageKeys
        return HStack {
            ForEach(visibleKeys, id: \.self) { settingKey in
                if let definition = SettingsSchema.definition(for: settingKey) {
                    Button {
                        phoneController.presetStore.cycleValue(settingKey)
                    } label: {
                        Text(settings.displayText(for: definition))
                            .font(.footnote)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var statusHeader: some View {
        VStack(spacing: 2) {
            Text("\(phoneController.relayStatus) · \(phoneController.scribeStatus) · audio: \(phoneController.audioOwner)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(phoneController.activityStatus)
                .font(.headline)
        }
    }

    private var controlButtons: some View {
        let settings = phoneController.presetStore.activeSettings
        return HStack(spacing: 16) {
            if settings.showDiscardButton {
                Button {
                    phoneController.secondaryAction()
                } label: {
                    Image(systemName: "xmark")
                        .font(.title)
                        .frame(maxWidth: .infinity, minHeight: 64)
                }
                .buttonStyle(.bordered)
            }
            if settings.showSendButton {
                Button {
                    phoneController.primaryAction()
                } label: {
                    Image(systemName: sendButtonIcon)
                        .font(.title)
                        .frame(maxWidth: .infinity, minHeight: 64)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var sendButtonIcon: String {
        let listening = phoneController.activityStatus == "recording" || phoneController.activityStatus == "listening"
        return listening ? "paperplane.fill" : "mic.fill"
    }
}
