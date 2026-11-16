import Foundation
import AppKit
import Combine

// MARK: - 模式

enum FanMode: String, CaseIterable, Identifiable {
    case auto      // 系统自动
    case target    // 目标温度（闭环恒温）
    case curve     // 自定义曲线
    case manual    // 固定转速

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto:   return "自动"
        case .target: return "恒温"
        case .curve:  return "曲线"
        case .manual: return "手动"
        }
    }

    var detail: String {
        switch self {
        case .auto:   return "完全交给系统固件控制，本程序只读取数据。"
        case .target: return "按你设定的目标温度自动增减转速，试图把温度压在目标附近。"
        case .curve:  return "按你自定义的「温度 → 转速」节点表线性插值调速。"
        case .manual: return "无论温度多少，都固定在指定转速。"
        }
    }
}

// MARK: - 网速单位

enum NetUnit: String, CaseIterable, Identifiable {
    case auto   // K / M 自适应
    case mbs2   // 固定 0.00 M/s
    case mb1    // 固定 0.0 M

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "自动"
        case .mbs2: return "0.00 M/s"
        case .mb1:  return "0.0 M"
        }
    }
}

// MARK: - 曲线节点

struct CurvePoint: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var temp: Double   // 触发温度 °C
    var rpm: Double    // 对应转速 RPM
}

// MARK: - 主状态

final class FanModel: ObservableObject {

    // 用户设置
    @Published var mode: FanMode = .auto {
        didSet {
            guard mode != oldValue else { return }
            defaults.set(mode.rawValue, forKey: Keys.mode)
            loopRPM = 0
            handleModeChange()
        }
    }

    @Published var targetTemp: Double = 68 {
        didSet {
            defaults.set(targetTemp, forKey: Keys.targetTemp)
            if mode == .target { applyNow() }
        }
    }

    @Published var manualRPM: Double = 3000 {
        didSet { defaults.set(manualRPM, forKey: Keys.manualRPM) }
    }

    @Published var curve: [CurvePoint] = [] {
        didSet { saveCurve() }
    }

    @Published var menuShowRPM: Bool = true {
        didSet { defaults.set(menuShowRPM, forKey: Keys.menuShowRPM) }
    }

    /// 状态栏显示网速（默认打开）
    @Published var menuShowNet: Bool = true {
        didSet { defaults.set(menuShowNet, forKey: Keys.menuShowNet) }
    }

    /// 网速单位：自动（K/M 自适应）或固定 MB/s
    @Published var netUnit: NetUnit = .auto {
        didSet { defaults.set(netUnit.rawValue, forKey: Keys.netUnit) }
    }

    /// 转速平滑过渡（开关 + 速率设定 + 分步过渡）
    @Published var smoothEnabled: Bool = true {
        didSet {
            defaults.set(smoothEnabled, forKey: Keys.smoothEnabled)
            if !smoothEnabled { flushSmooth() }
        }
    }

    /// 平滑速率：RPM / 秒
    @Published var smoothRate: Double = 500 {
        didSet { defaults.set(smoothRate, forKey: Keys.smoothRate) }
    }

    // 运行状态
    @Published private(set) var fans: [FStatus.Fan] = []
    @Published private(set) var temps: [FStatus.T] = []
    @Published private(set) var helperReady = false
    @Published private(set) var lastError: String?
    @Published private(set) var autostartEnabled = Autostart.isEnabled
    @Published private(set) var lastUpdate = Date.distantPast
    /// 最近一次读到的有效转速：偶尔 SMC 读失败时用它兜底，避免状态栏闪成 "--"
    private var lastKnownRPM: Double = 0
    /// 最近一次真正写入 SMC 的目标转速（平滑过渡时会在目标与当前之间移动）
    @Published private(set) var writtenRPM: Double = -1
    /// 网速镜像值（让菜单栏与面板随网速刷新）
    @Published private(set) var netUp: Double = 0
    @Published private(set) var netDown: Double = 0

    private let defaults = UserDefaults.standard
    let updater = Updater()
    let net = NetMonitor()
    private let ioQueue = DispatchQueue(label: "com.local.ifeng.io")
    private var timer: Timer?
    private var tickCount = 0

    // 控制状态
    private var pendingTarget: Double = -1     // 本周期期望目标
    private var rampRPM: Double = -1           // 平滑过渡中的当前输出
    private var lastWrittenRPM: Double = -1    // 最近一次真正写入 SMC 的值
    private var lastApplyTime = Date.distantPast
    private var loopRPM: Double = 0            // 恒温闭环内部状态
    private var curveSeeded = false
    private var cancellables = Set<AnyCancellable>()

    private enum Keys {
        static let mode          = "ifeng.mode"
        static let targetTemp    = "ifeng.targetTemp"
        static let manualRPM     = "ifeng.manualRPM"
        static let curve         = "ifeng.curve"
        static let menuShowRPM   = "ifeng.menuShowRPM"
        static let menuShowNet   = "ifeng.menuShowNet"
        static let netUnit       = "ifeng.netUnit"
        static let smoothEnabled = "ifeng.smoothEnabled"
        static let smoothRate    = "ifeng.smoothRate"
    }

    // MARK: 生命周期

    init() {
        let d = defaults
        if let raw = d.string(forKey: Keys.mode), let m = FanMode(rawValue: raw) { mode = m }
        if d.object(forKey: Keys.targetTemp) != nil { targetTemp = d.double(forKey: Keys.targetTemp) }
        if d.object(forKey: Keys.manualRPM) != nil { manualRPM = d.double(forKey: Keys.manualRPM) }
        if d.object(forKey: Keys.menuShowRPM) != nil { menuShowRPM = d.bool(forKey: Keys.menuShowRPM) }
        if d.object(forKey: Keys.menuShowNet) != nil { menuShowNet = d.bool(forKey: Keys.menuShowNet) }
        if let raw = d.string(forKey: Keys.netUnit), let u = NetUnit(rawValue: raw) { netUnit = u }
        if d.object(forKey: Keys.smoothEnabled) != nil { smoothEnabled = d.bool(forKey: Keys.smoothEnabled) }
        if d.object(forKey: Keys.smoothRate) != nil { smoothRate = d.double(forKey: Keys.smoothRate) }
        loadCurve()

        helperReady = Helper.helperReady

        if mode == .auto {
            ioQueue.async { Helper.restoreAuto() }
        }

        refresh()
        updater.bootstrap()
        net.start()

        // 网速是独立对象，镜像到自身才能驱动菜单栏与面板刷新
        net.$upBytesPerSec
            .combineLatest(net.$downBytesPerSec)
            .sink { [weak self] up, down in
                self?.netUp = up
                self?.netDown = down
            }
            .store(in: &cancellables)

        // 0.25 秒基准节拍：平滑过渡每拍走一步，每 8 拍（2 秒）读一次 SMC
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.onTick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit { timer?.invalidate() }

    private func onTick() {
        tickCount &+= 1
        if tickCount % 8 == 0 { refresh() }
        if smoothEnabled && mode != .auto { rampStep() }
    }

    // MARK: 派生属性

    var maxTemp: Double? {
        temps.map { $0.v }.filter { $0 > 1 && $0 < 120 }.max()
    }

    /// 控制用温度：优先「CPU 附近」(TC0P)。
    ///
    /// 为什么不用 maxTemp：本机 TC0E / TC0F 常年 82–87 ℃，即使空闲也很高，
    /// 用它做控制量会让目标温度 66 ℃ 永远超差 —— 风扇一直全速，恒温模式形同失效。
    /// TC0P 与用户设定目标温度的语义一致，Macs Fan Control 也以它为准。
    /// maxTemp 仍保留，用于过热强制全速这类安全判断。
    var controlTemp: Double? {
        if let p = temps.first(where: { $0.k == "TC0P" }), p.v > 1, p.v < 120 {
            return p.v
        }
        return maxTemp
    }

    var primaryRPM: Double { fans.first?.ac ?? 0 }

    /// 硬件真实下限 / 上限
    var fanMin: Double { fans.first?.mn ?? 1200 }
    var fanMax: Double { fans.first?.mx ?? 6200 }

    /// 可调范围：下限放到 0，允许手动关停（能否真正停转由 SMC 决定）
    var sliderRange: ClosedRange<Double> {
        return 0...max(fanMax, 1000)
    }

    var isForcing: Bool { fans.contains { $0.md != 0 } }

    /// 网速单独成串，方便放到风扇图标左侧
    var netText: String {
        "↑\(netValueText(netUp)) ↓\(netValueText(netDown))"
    }

    /// 定长输出：宽度固定，网速跳动时菜单栏不会左右晃
    private func netValueText(_ v: Double) -> String {
        switch netUnit {
        case .auto:
            let kb = v / 1024.0
            if kb < 1000 { return String(format: "%4.0fK", kb) }
            let mb = kb / 1024.0
            return mb < 100 ? String(format: "%4.1fM", mb) : String(format: "%4.0fM", mb)
        case .mbs2:
            return String(format: "%5.2fM/s", v / 1_048_576.0)
        case .mb1:
            return String(format: "%5.1fM", v / 1_048_576.0)
        }
    }

    /// 图标右侧：温度与转速分开，便于各自固定宽度、互不挤动
    var tempBarText: String {
        controlTemp.map { String(format: "%3.0f°", $0) } ?? " --°"
    }

    var rpmBarText: String {
        let v = primaryRPM > 1 ? primaryRPM : lastKnownRPM
        return v > 1 ? String(format: "%4d", Int(v.rounded())) : "  --"
    }

    var targetDeviation: Double? {
        guard let t = controlTemp else { return nil }
        return t - targetTemp
    }

    var curveRPM: Double { rpmFor(temp: controlTemp ?? targetTemp) }

    var statusColorHint: String {
        guard let t = controlTemp else { return "" }
        if t >= 90 { return "温度偏高" }
        if t >= 78 { return "偏热" }
        if t <= 55 { return "凉爽" }
        return "正常"
    }

    /// 满量程过渡耗时（界面上给用户一个直观概念）
    var smoothTimeHint: String {
        let span = sliderRange.upperBound - sliderRange.lowerBound
        let sec = span / max(50, smoothRate)
        return String(format: "满量程约 %.0f 秒", sec)
    }

    /// 是否正在平滑过渡中
    var isRamping: Bool {
        guard smoothEnabled, pendingTarget >= 0, writtenRPM >= 0 else { return false }
        return abs(pendingTarget - writtenRPM) >= 15
    }

    // MARK: 数据刷新

    func refresh() {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            let st = Helper.status()
            DispatchQueue.main.async {
                guard let st = st else {
                    self.helperReady = false
                    self.lastError = Helper.installed
                        ? "无法读取 SMC，请检查辅助工具权限"
                        : "未安装辅助工具 /usr/local/bin/fanctl，请先执行 install.sh"
                    return
                }
                self.helperReady = st.ok && Helper.helperReady
                self.fans = st.fans
                if let f = st.fans.first, f.ac > 1 { self.lastKnownRPM = f.ac }
                self.temps = st.temps
                self.lastError = st.ok
                    ? (Helper.helperReady ? nil : "尚未启用风扇写入，请在「设置」里点「一键启用」")
                    : (st.err ?? "SMC 读取失败")
                self.lastUpdate = Date()
                self.ensureDefaultCurve()
                self.enforcePolicy()
            }
        }
    }

    // MARK: 曲线

    private func ensureDefaultCurve() {
        guard !curveSeeded, curve.isEmpty, let fan = fans.first else { return }
        curveSeeded = true
        let mn = fan.mn
        let span = fan.mx - mn
        curve = [
            CurvePoint(temp: 42, rpm: mn),
            CurvePoint(temp: 55, rpm: ((mn + span * 0.18) / 10).rounded() * 10),
            CurvePoint(temp: 65, rpm: ((mn + span * 0.32) / 10).rounded() * 10),
            CurvePoint(temp: 75, rpm: ((mn + span * 0.55) / 10).rounded() * 10),
            CurvePoint(temp: 85, rpm: ((mn + span * 0.82) / 10).rounded() * 10),
            CurvePoint(temp: 95, rpm: fan.mx)
        ]
    }

    func rpmFor(temp: Double) -> Double {
        let pts = curve.sorted { $0.temp < $1.temp }
        guard let first = pts.first, let last = pts.last else {
            return sliderRange.lowerBound
        }
        if temp <= first.temp { return clamp(first.rpm) }
        if temp >= last.temp { return clamp(last.rpm) }
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            if temp >= a.temp && temp <= b.temp {
                let span = max(0.1, b.temp - a.temp)
                let ratio = (temp - a.temp) / span
                return clamp(a.rpm + (b.rpm - a.rpm) * ratio)
            }
        }
        return clamp(last.rpm)
    }

    func addCurvePoint() {
        let sorted = curve.sorted { $0.temp < $1.temp }
        let newTemp: Double = sorted.last.map { min(100, $0.temp + 5) } ?? 65
        let r = sliderRange
        let mid = ((r.lowerBound + r.upperBound) / 2 / 10).rounded() * 10
        curve.append(CurvePoint(temp: newTemp, rpm: mid))
        curve.sort { $0.temp < $1.temp }
        if mode == .curve { applyNow() }
    }

    /// 只改数据、不立即下发。拖动过程中每帧都会调用，避免刷爆 SMC。
    func updatePoint(_ id: UUID, temp: Double? = nil, rpm: Double? = nil) {
        guard let idx = curve.firstIndex(where: { $0.id == id }) else { return }
        var p = curve[idx]
        if let t = temp { p.temp = min(105, max(30, t.rounded())) }
        if let v = rpm { p.rpm = (clamp(v) / 10).rounded() * 10 }
        curve[idx] = p
        curve.sort { $0.temp < $1.temp }
    }

    func removePoint(_ id: UUID) {
        guard curve.count > 2 else { return }
        curve.removeAll { $0.id == id }
        if mode == .curve { applyNow() }
    }

    func resetCurve() {
        curve.removeAll()
        curveSeeded = false
        ensureDefaultCurve()
        if mode == .curve { applyNow() }
    }

    private func saveCurve() {
        guard let d = try? JSONEncoder().encode(curve),
              let s = String(data: d, encoding: .utf8) else { return }
        defaults.set(s, forKey: Keys.curve)
    }

    private func loadCurve() {
        guard let s = defaults.string(forKey: Keys.curve),
              let d = s.data(using: .utf8),
              let arr = try? JSONDecoder().decode([CurvePoint].self, from: d),
              !arr.isEmpty else { return }
        curve = arr
        curveSeeded = true
    }

    // MARK: 目标转速

    private func clamp(_ rpm: Double) -> Double {
        let r = sliderRange
        return min(max(rpm, r.lowerBound), r.upperBound)
    }

    /// 允许把转速设为 0（用户要求），但温度偏高时不允许真停转。
    /// 实测本机设 0 会让风扇完全停转、核心温度几分钟内冲到 84 ℃，必须兜住。
    private func safetyFloor(_ v: Double) -> Double {
        guard v < fanMin else { return v }
        if let m = maxTemp, m >= 58 { return fanMin }
        return v
    }

    private func desiredRPM(advance: Bool = true) -> Double {
        switch mode {
        case .auto:
            return 0
        case .manual:
            return safetyFloor(clamp(manualRPM))
        case .curve:
            return safetyFloor(rpmFor(temp: controlTemp ?? targetTemp))
        case .target:
            return safetyFloor(loopTarget(advance: advance))
        }
    }

    /// 恒温闭环：以目标温度为设定值，按误差比例增减转速
    private func loopTarget(advance: Bool = true) -> Double {
        let r = sliderRange
        guard let t = controlTemp else { return clamp(manualRPM) }

        // 过热保护按最高温判断，与显示/控制用的 TC0P 分开
        if let m = maxTemp, m >= 95 { return r.upperBound }

        var rpm = loopRPM
        if rpm <= 0 { rpm = rpmFor(temp: targetTemp) }
        guard advance else { return clamp(rpm) }

        let err = t - targetTemp
        if err > 1.5 {
            rpm += min(450, 90 * err)
        } else if err < -1.5 {
            rpm -= min(350, 80 * (-err))
        }
        loopRPM = clamp(rpm)
        return loopRPM
    }

    // MARK: 下发与平滑

    private func handleModeChange() {
        pendingTarget = -1
        rampRPM = -1

        if mode == .auto {
            ioQueue.async { Helper.restoreAuto() }
            lastWrittenRPM = -1
            lastApplyTime = Date.distantPast
            return
        }
        applyNow()
    }

    /// 平滑起点：优先取风扇当前实际转速，其次取上次写入值。
    /// 之前直接用 lastWrittenRPM，而刚离开「自动」模式时它是 -1，
    /// 于是平滑起点被设成目标值本身 —— 差值恒为 0，速率设置自然毫无效果。
    private func rampSeed() -> Double {
        if let f = fans.first, f.ac > 1 { return f.ac }
        if lastWrittenRPM >= 0 { return lastWrittenRPM }
        return pendingTarget >= 0 ? pendingTarget : 0
    }

    /// 按当前模式把目标下发；开启平滑时由 rampStep 逐步逼近
    func applyNow() {
        guard mode != .auto else { return }
        let target = desiredRPM(advance: false)
        pendingTarget = target

        if smoothEnabled {
            if rampRPM < 0 { rampRPM = rampSeed() }
        } else {
            writeAllAsync(target)
        }
    }

    private func enforcePolicy() {
        guard mode != .auto, !fans.isEmpty else { return }

        let target = desiredRPM(advance: true)
        pendingTarget = target

        guard !smoothEnabled else {
            if rampRPM < 0 { rampRPM = rampSeed() }
            return
        }

        let stale = Date().timeIntervalSince(lastApplyTime) > 25
        if abs(target - lastWrittenRPM) >= 60 || stale || !isForcing {
            writeAllAsync(target)
        }
    }

    /// 平滑推进：每个 0.25 秒节拍最多走 rate × dt 转
    private func rampStep() {
        guard pendingTarget >= 0, !fans.isEmpty else { return }
        if rampRPM < 0 { rampRPM = rampSeed() }

        let dt = 0.25
        let maxStep = max(10, smoothRate * dt)
        let diff = pendingTarget - rampRPM

        var next: Double
        if abs(diff) <= maxStep {
            next = pendingTarget
        } else {
            next = rampRPM + (diff > 0 ? maxStep : -maxStep)
        }
        next = (clamp(next) / 10).rounded() * 10
        rampRPM = next

        guard abs(next - lastWrittenRPM) >= 10 else { return }
        writeAllAsync(next)
    }

    /// 关闭平滑时把目标一次性写下去
    private func flushSmooth() {
        guard pendingTarget >= 0 else { return }
        rampRPM = pendingTarget
        writeAllAsync(pendingTarget)
    }

    private func writeAllAsync(_ rpm: Double) {
        let list = fans
        lastWrittenRPM = rpm
        writtenRPM = rpm
        lastApplyTime = Date()
        ioQueue.async {
            var targets = list
            if targets.isEmpty, let st = Helper.status() { targets = st.fans }
            for f in targets { Helper.setFan(f.i, rpm: rpm) }
        }
    }

    // MARK: 其它

    func restoreAuto() {
        mode = .auto
        loopRPM = 0
        ioQueue.async { Helper.restoreAuto() }
    }

    func quitSafely() {
        Helper.restoreAuto()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.terminate(nil)
        }
    }

    func toggleAutostart(_ on: Bool) {
        if on {
            Autostart.enable { [weak self] ok in
                DispatchQueue.main.async { self?.autostartEnabled = ok ? Autostart.isEnabled : false }
            }
        } else {
            Autostart.disable { [weak self] _ in
                DispatchQueue.main.async { self?.autostartEnabled = Autostart.isEnabled }
            }
        }
    }

    func refreshAutostartState() { autostartEnabled = Autostart.isEnabled }

    /// 一键安装 setuid 辅助工具（弹一次系统密码框，不需要终端）
    func requestHelperInstall() {
        lastError = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            Helper.installHelper { ok, msg in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.helperReady = ok
                    if !ok { self.lastError = msg }
                    self.refresh()
                }
            }
        }
    }
}
