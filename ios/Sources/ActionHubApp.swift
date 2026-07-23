import BackgroundTasks
import SwiftUI

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        BackgroundRefresh.register()
        BackgroundRefresh.requestNotificationPermission()
        return true
    }
}

@main
struct ActionHubApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var phoneController = PhoneController()
    @StateObject private var inboxStore = InboxStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView {
                InboxView()
                    .environmentObject(inboxStore)
                    .tabItem { Label("Inbox", systemImage: "tray") }
                MainView()
                    .environmentObject(phoneController)
                    .tabItem { Label("Voice", systemImage: "mic") }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .background {
                    BackgroundRefresh.schedule()
                }
            }
        }
    }
}
