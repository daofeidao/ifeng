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
            // 注意：这里不能写 if 分支。MenuBarExtra 的 label 里用 if 会让子视图错位、
            // 甚至整段被吞掉（实测：温度和转速消失、网速跑到图标右侧）。
            // 改用「始终存在的 Text + 宽度控制显隐」，布局才是稳定的。
            HStack(spacing: 3) {
                Text(model.menuShowNet ? model.netText : "")
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
                    .frame(width: model.menuShowNet ? 104 : 0, alignment: .trailing)
                    .lineLimit(1)

                Image(systemName: "fanblades.fill")

                Text(model.tempBarText)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .frame(width: 30, alignment: .trailing)
                    .lineLimit(1)

                Text(model.menuShowRPM ? model.rpmBarText : "")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .frame(width: model.menuShowRPM ? 32 : 0, alignment: .trailing)
                    .lineLimit(1)
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
