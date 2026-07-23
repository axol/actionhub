import SwiftUI

@main
struct ActionHubApp: App {
    @StateObject private var phoneController = PhoneController()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(phoneController)
        }
    }
}
