import SwiftUI
import AppKit
import Dispatch

@main
struct IFengApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = FanModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView(model: model, updater: model.updater)
        } label: {
            HStack(spacing: 4) {
                // 网速放在风扇图标左侧
                if model.menuShowNet {
                    Text(model.netText)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                }
                Image(systemName: "fanblades.fill")
                Text(model.barTextAfterIcon)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var sigTermSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = NSApp.setActivationPolicy(.accessory)
        installSignalHandlers()
    }

    /// 被 kill 或注销时也尽量把风扇交还系统
    private func installSignalHandlers() {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler {
            Helper.restoreAuto()
            NSApp.terminate(nil)
        }
        src.resume()
        sigTermSource = src
    }

    func applicationWillTerminate(_ notification: Notification) {
        Helper.restoreAuto()
    }
}
