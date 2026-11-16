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
            // 整条自己排版后画成一张图交给系统。
            // 顺序：网速 → 风扇图标 → 温度 → 转速
            // （MenuBarExtra 的 label 只渲染一个 Text，多视图会被丢弃，见 StatusBar.swift）
            Image(nsImage: BarImage.make(
                net: model.menuShowNet ? model.netText : nil,
                temp: model.tempBarText,
                rpm: model.menuShowRPM ? model.rpmBarText : nil
            ))
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
