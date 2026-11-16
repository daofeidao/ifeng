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
            // 顺序：网速 → 风扇图标 → 温度 → 转速
            // 每一段都固定宽度，否则数值变化时整排会左右晃
            HStack(spacing: 3) {
                if model.menuShowNet {
                    Text(model.netText)
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .frame(width: 104, alignment: .trailing)
                        .lineLimit(1)
                }
                Image(systemName: "fanblades.fill")
                Text(model.tempBarText)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .frame(width: 30, alignment: .trailing)
                    .lineLimit(1)
                if model.menuShowRPM {
                    Text(model.rpmBarText)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .frame(width: 32, alignment: .trailing)
                        .lineLimit(1)
                }
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
