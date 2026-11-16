import Foundation
import AppKit
import Combine

enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }
    static var short: String { version }

    /// 项目主页（应用内「GitHub」链接、自动更新都指向这里）
    static let repoURL = URL(string: "https://github.com/daofeidao/ifeng")!
    static let author = "张宏亮"
}

struct ReleaseInfo {
    var version: String
    var notes: String
    var pageURL: URL?
    var assetURL: URL?
}

/// 更新器：启动静默检查 → 后台自动下载并校验 → 就绪后提示 → 一键重启安装
final class Updater: ObservableObject {

    static let owner = "daofeidao"
    static let repo = "ifeng"

    @Published var checking = false
    @Published var downloading = false
    @Published var installing = false
    @Published var message = "尚未检查"
    @Published var lastError: String?
    @Published var latest: ReleaseInfo?
    @Published var lastChecked: Date?
    @Published private(set) var stagedVersion: String?

    /// 启动时自动检查并后台下载
    @Published var autoUpdate: Bool = true {
        didSet { UserDefaults.standard.set(autoUpdate, forKey: "ifeng.autoUpdate") }
    }

    var currentVersion: String { AppInfo.version }

    var hasUpdate: Bool {
        guard let l = latest else { return false }
        return Updater.compareVersion(l.version, currentVersion) > 0
    }

    /// 已下载完毕、等待安装
    var readyToInstall: Bool {
        guard let v = stagedVersion else { return false }
        return Updater.compareVersion(v, currentVersion) > 0
    }

    private var bootstrapped = false
    private var pollTimer: Timer?

    // MARK: 版本比较

    static func compareVersion(_ a: String, _ b: String) -> Int {
        func parts(_ s: String) -> [Int] {
            let trimmed = s.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            return trimmed.split(separator: ".").map { seg in
                Int(seg.prefix(while: { $0.isNumber })) ?? 0
            }
        }
        let x = parts(a)
        let y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l > r ? 1 : -1 }
        }
        return 0
    }

    // MARK: 暂存目录

    static var stagingRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("iFeng/update", isDirectory: true)
    }

    /// 已暂存待安装的 App 路径
    var stagedAppPath: String? {
        guard let v = stagedVersion else { return nil }
        let dir = Updater.stagingRoot.appendingPathComponent(v).appendingPathComponent("pkg")
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.first(where: { $0.pathExtension == "app" })?.path
    }

    // MARK: 启动引导

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true

        if UserDefaults.standard.object(forKey: "ifeng.autoUpdate") != nil {
            autoUpdate = UserDefaults.standard.bool(forKey: "ifeng.autoUpdate")
        }

        recoverStaged()
        cleanupStale()

        guard autoUpdate else { return }

        // 启动 5 秒后静默检查一次，之后每小时一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.check(silent: true)
        }
        let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            self?.check(silent: true)
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    /// 上次已下载好的包，重启后仍可提示
    private func recoverStaged() {
        let fm = FileManager.default
        let root = Updater.stagingRoot
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for d in dirs {
            let pkg = d.appendingPathComponent("pkg")
            let items = (try? fm.contentsOfDirectory(at: pkg, includingPropertiesForKeys: nil)) ?? []
            guard let app = items.first(where: { $0.pathExtension == "app" }) else { continue }
            let plist = app.appendingPathComponent("Contents/Info.plist")
            let v = (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String) ?? d.lastPathComponent
            if Updater.compareVersion(v, currentVersion) > 0 {
                stagedVersion = v
                message = "新版本 \(v) 已下载，可点「重启并安装」"
                return
            }
        }
    }

    private func cleanupStale() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: Updater.stagingRoot, includingPropertiesForKeys: nil) else { return }
        for d in dirs {
            let v = d.lastPathComponent
            if Updater.compareVersion(v, currentVersion) <= 0 {
                try? fm.removeItem(at: d)
            }
        }
    }

    // MARK: 检查更新

    func check(silent: Bool = false) {
        guard !checking else { return }
        checking = true
        if !silent { message = "检查中…" }
        lastError = nil

        checkViaAPI { [weak self] info, apiError in
            guard let self = self else { return }
            if let info = info {
                DispatchQueue.main.async { self.finish(info) }
                return
            }
            // API 不可达（国内网络/限流很常见）时，退回 releases/latest 的重定向地址，
            // 从最终 URL 里取 tag，再拼出下载链接 —— 不依赖 api.github.com。
            self.checkViaRedirect { info2, redirectError in
                DispatchQueue.main.async {
                    if let info2 = info2 {
                        self.finish(info2)
                    } else {
                        self.checking = false
                        self.lastChecked = Date()
                        let detail = [apiError, redirectError].compactMap { $0 }.joined(separator: "；")
                        self.lastError = detail.isEmpty ? "未知原因" : detail
                        self.message = "检查失败：\(self.lastError ?? "")"
                    }
                }
            }
        }
    }

    /// 面板每次打开时补一次：距上次检查超过 N 分钟才真正发请求
    func checkIfStale(minutes: Double = 30) {
        guard autoUpdate else { return }
        if let t = lastChecked, Date().timeIntervalSince(t) < minutes * 60 { return }
        check(silent: true)
    }

    private func finish(_ info: ReleaseInfo) {
        checking = false
        lastChecked = Date()
        latest = info
        lastError = nil

        if Updater.compareVersion(info.version, currentVersion) > 0 {
            if readyToInstall {
                message = "新版本 \(info.version) 已下载，可点「重启并安装」"
            } else if autoUpdate, !downloading {
                message = "发现新版本 \(info.version)，开始后台下载…"
                download(info)
            } else {
                message = "发现新版本 \(info.version)（当前 \(currentVersion)）"
            }
        } else {
            message = "已是最新版本（\(currentVersion)）"
        }
    }

    /// 通道一：GitHub API
    private func checkViaAPI(_ done: @escaping (ReleaseInfo?, String?) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.owner)/\(Self.repo)/releases/latest") else {
            done(nil, "内部错误")
            return
        }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 12

        URLSession.shared.dataTask(with: req) { data, resp, error in
            if let error = error {
                done(nil, "api.github.com 不可达（\(error.localizedDescription)）")
                return
            }
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                done(nil, "api.github.com 返回 \(http.statusCode)")
                return
            }
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String else {
                done(nil, "响应无法解析")
                return
            }

            var info = ReleaseInfo(version: tag, notes: obj["body"] as? String ?? "")
            if let s = obj["html_url"] as? String { info.pageURL = URL(string: s) }
            if let assets = obj["assets"] as? [[String: Any]] {
                for a in assets {
                    if let n = a["name"] as? String, n.hasSuffix(".zip"),
                       let u = a["browser_download_url"] as? String,
                       let au = URL(string: u) {
                        info.assetURL = au
                        break
                    }
                }
            }
            done(info, nil)
        }.resume()
    }

    /// 通道二：github.com 的 releases/latest 重定向，从最终 URL 取 tag
    private func checkViaRedirect(_ done: @escaping (ReleaseInfo?, String?) -> Void) {
        guard let url = URL(string: "https://github.com/\(Self.owner)/\(Self.repo)/releases/latest") else {
            done(nil, "内部错误")
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12

        URLSession.shared.dataTask(with: req) { _, resp, error in
            if let error = error {
                done(nil, "github.com 不可达（\(error.localizedDescription)）")
                return
            }
            guard let finalURL = resp?.url else {
                done(nil, "无重定向结果")
                return
            }
            let comps = finalURL.pathComponents
            guard let idx = comps.firstIndex(of: "tag"), idx + 1 < comps.count else {
                done(nil, "未能从地址解析版本（\(finalURL.path)）")
                return
            }
            let tag = comps[idx + 1]
            let bare = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag

            var info = ReleaseInfo(version: tag, notes: "")
            info.pageURL = finalURL
            info.assetURL = URL(string: "https://github.com/\(Self.owner)/\(Self.repo)/releases/download/\(tag)/iFeng-\(bare).zip")
            done(info, nil)
        }.resume()
    }

    // MARK: 后台下载

    /// 手动触发下载（自动流程也会调）
    func download(_ info: ReleaseInfo) {
        guard let asset = info.assetURL else {
            message = "该版本未提供 zip 资源"
            return
        }
        guard !downloading else { return }
        downloading = true
        message = "正在后台下载 \(info.version)…"

        URLSession.shared.downloadTask(with: asset) { [weak self] tmp, _, error in
            guard let self = self else { return }

            func fail(_ text: String) {
                DispatchQueue.main.async {
                    self.downloading = false
                    self.message = text
                }
            }

            guard let tmp = tmp, error == nil else {
                fail("下载失败：\(error?.localizedDescription ?? "未知错误")")
                return
            }

            let fm = FileManager.default
            let dir = Updater.stagingRoot.appendingPathComponent(info.version)
            do {
                try? fm.removeItem(at: dir)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)

                let zip = dir.appendingPathComponent("update.zip")
                try fm.moveItem(at: tmp, to: zip)

                let out = dir.appendingPathComponent("pkg")
                try fm.createDirectory(at: out, withIntermediateDirectories: true)
                guard Updater.run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path]) == 0 else {
                    fail("解压失败"); return
                }

                let items = (try? fm.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)) ?? []
                guard let app = items.first(where: { $0.pathExtension == "app" }) else {
                    fail("压缩包内未找到 App"); return
                }
                let plist = app.appendingPathComponent("Contents/Info.plist")
                let v = (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String) ?? ""
                guard Updater.compareVersion(v, self.currentVersion) > 0 else {
                    fail("下载内容版本异常（\(v)）"); return
                }
                guard fm.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/iFeng").path) else {
                    fail("压缩包内可执行文件缺失"); return
                }

                try? fm.removeItem(at: zip)

                DispatchQueue.main.async {
                    self.downloading = false
                    self.stagedVersion = v
                    self.message = "新版本 \(v) 已下载，可点「重启并安装」"
                }
            } catch {
                fail("下载处理失败：\(error.localizedDescription)")
            }
        }.resume()
    }

    // MARK: 安装

    func installStaged() {
        guard let path = stagedAppPath else {
            message = "没有可安装的更新包"
            return
        }
        installing = true
        swapAndRelaunch(newApp: path)
    }

    private func swapAndRelaunch(newApp: String) {
        let dst = Bundle.main.bundlePath
        guard dst.hasPrefix("/Applications/") else {
            installing = false
            message = "当前为开发态运行，请手动替换：\(newApp)"
            return
        }

        // 用户约定：桌面 app 文件夹也保留一份，更新后一并刷新
        let home = NSHomeDirectory()
        let deskDir = home + "/Desktop/app"
        let deskApp = deskDir + "/风扇控制.app"

        let script = """
        #!/bin/bash
        PID=\(getpid())
        NEW='\(newApp)'
        DST='\(dst)'
        DESK_DIR='\(deskDir)'
        DESK_APP='\(deskApp)'
        while /bin/kill -0 "$PID" 2>/dev/null; do /bin/sleep 0.3; done
        /bin/sleep 0.6
        /bin/rm -rf "$DST.ifeng-old"
        /bin/mv "$DST" "$DST.ifeng-old" 2>/dev/null
        /usr/bin/ditto "$NEW" "$DST"
        /usr/bin/xattr -cr "$DST" 2>/dev/null
        /bin/rm -rf "$DST.ifeng-old"
        if [ -d "$(/usr/bin/dirname "$DESK_DIR")" ]; then
            /bin/mkdir -p "$DESK_DIR"
            /bin/rm -rf "$DESK_APP"
            /usr/bin/ditto "$DST" "$DESK_APP"
            /usr/bin/xattr -cr "$DESK_APP" 2>/dev/null
        fi
        /usr/bin/open "$DST"
        """

        let path = "/tmp/ifeng-swap-\(getpid()).sh"
        do {
            try script.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            installing = false
            message = "无法生成更新脚本"
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [path]
        do {
            try p.run()
        } catch {
            installing = false
            message = "无法启动更新脚本"
            return
        }

        message = "正在安装 \(stagedVersion ?? "")，应用将自动重启"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }

    // MARK: 杂项

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    func openReleasePage() {
        if let p = latest?.pageURL {
            NSWorkspace.shared.open(p)
        } else if let u = URL(string: "https://github.com/\(Self.owner)/\(Self.repo)/releases") {
            NSWorkspace.shared.open(u)
        }
    }
}
