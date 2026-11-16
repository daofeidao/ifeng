import Foundation

// MARK: - fanctl 输出结构

struct FStatus: Decodable {
    struct Fan: Decodable {
        let i: Int
        let ac: Double      // 实际转速
        let mn: Double      // 最低转速
        let mx: Double      // 最高转速
        let tg: Double      // 目标转速
        let md: Int         // 1 = 强制模式
    }

    struct T: Decodable, Identifiable {
        let k: String
        let n: String
        let v: Double
        var id: String { k }
    }

    let ok: Bool
    let root: Bool?
    let fans: [Fan]
    let temps: [T]
    let err: String?
}

// MARK: - 辅助工具调用层

enum Helper {

    static let binPath = "/usr/local/bin/fanctl"

    static var installed: Bool {
        FileManager.default.isExecutableFile(atPath: binPath)
    }

    /// 同步执行 fanctl，返回 (退出码, stdout)
    @discardableResult
    static func run(_ args: [String]) -> (Int32, Data) {
        return runTool(binPath, args)
    }

    @discardableResult
    static func runTool(_ path: String, _ args: [String]) -> (Int32, Data) {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return (-1, Data())
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = Pipe()

        do {
            try p.run()
        } catch {
            return (-2, Data())
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }

    /// 解析 `fanctl list` 的 JSON
    static func status() -> FStatus? {
        let (_, data) = run(["list"])
        guard !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(FStatus.self, from: data)
    }

    @discardableResult
    static func setFan(_ index: Int, rpm: Double) -> Bool {
        let (code, data) = run(["set", "\(index)", "\(Int(rpm.rounded()))"])
        guard code == 0, !data.isEmpty else { return false }
        struct R: Decodable { let ok: Bool }
        return (try? JSONDecoder().decode(R.self, from: data))?.ok ?? false
    }

    @discardableResult
    static func restoreAuto() -> Bool {
        let (code, _) = run(["auto", "all"])
        return code == 0
    }

    // MARK: 辅助工具一键安装（免终端）

    /// App 包内随附的 fanctl
    static var bundledPath: String? {
        Bundle.main.path(forResource: "fanctl", ofType: nil)
    }

    /// 已安装且带 setuid 位（真正能写 SMC 的前提）
    static var helperReady: Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: binPath, isDirectory: &isDir),
              !isDir.boolValue else { return false }
        let attrs = try? FileManager.default.attributesOfItem(atPath: binPath)
        let mode = (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? 0
        return (mode & 0o4000) != 0
    }

    /// 把内置 fanctl 复制到 /tmp，再通过系统授权框以 root 安装到 /usr/local/bin
    /// 全程不需要用户开终端，只弹一次标准密码框。
    static func installHelper(completion: @escaping (Bool, String) -> Void) {
        guard let src = bundledPath else {
            completion(false, "App 内未找到 fanctl，请使用 install.sh 安装")
            return
        }

        let tmpBin = "/tmp/ifeng-fanctl-\(getpid())"
        let fm = FileManager.default
        try? fm.removeItem(atPath: tmpBin)
        do {
            try fm.copyItem(atPath: src, toPath: tmpBin)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmpBin)
        } catch {
            completion(false, "准备安装文件失败：\(error.localizedDescription)")
            return
        }

        let scriptPath = "/tmp/ifeng-install-\(getpid()).sh"
        let script = """
        #!/bin/bash
        set -e
        /usr/bin/install -d -o root -g wheel -m 755 /usr/local/bin
        /usr/bin/install -o root -g wheel -m 4755 '\(tmpBin)' /usr/local/bin/fanctl
        /bin/rm -f '\(tmpBin)'
        """
        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        } catch {
            completion(false, "写入安装脚本失败")
            return
        }

        let apple = "do shell script \"/bin/bash \(scriptPath)\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", apple]
        p.standardOutput = Pipe()
        p.standardError = Pipe()

        do {
            try p.run()
        } catch {
            completion(false, "无法调用系统授权")
            return
        }
        p.waitUntilExit()

        try? fm.removeItem(atPath: scriptPath)

        if p.terminationStatus != 0 {
            completion(false, "已取消或授权失败")
            return
        }
        if helperReady {
            completion(true, "辅助工具已就绪")
        } else {
            completion(false, "安装完成但校验未通过，请用 install.sh 重试")
        }
    }
}

// MARK: - 开机自启（LaunchAgent）

enum Autostart {

    static let label = "com.local.ifeng"

    /// 安装在 /Applications 下则用真实路径，开发态回落到安装路径
    static var appPath: String {
        let p = Bundle.main.bundlePath
        if p.hasPrefix("/Applications/") { return p }
        return "/Applications/风扇控制.app"
    }

    static var appBinary: String { appPath + "/Contents/MacOS/iFeng" }

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func enable(completion: @escaping (Bool) -> Void) {
        let dir = plistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [appBinary],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive"
        ]
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: dict, format: .xml, options: 0) else {
            completion(false); return
        }
        do {
            try data.write(to: plistURL)
        } catch {
            completion(false); return
        }

        let uid = String(getuid())
        let (code, _) = Helper.runTool("/bin/launchctl",
                                       ["bootstrap", "gui/\(uid)", plistURL.path])
        if code != 0 {
            Helper.runTool("/bin/launchctl", ["load", "-w", plistURL.path])
        }
        completion(true)
    }

    static func disable(completion: @escaping (Bool) -> Void) {
        let uid = String(getuid())
        Helper.runTool("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
        Helper.runTool("/bin/launchctl", ["unload", "-w", plistURL.path])
        try? FileManager.default.removeItem(at: plistURL)
        completion(true)
    }
}
