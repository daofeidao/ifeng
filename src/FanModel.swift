import Foundation
import AppKit

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

    private let defaults = UserDefaults.standard
    let updater = Updater()
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

    private enum Keys {
        static let mode          = "ifeng.mode"
        static let targetTemp    = "ifeng.targetTemp"
        static let manualRPM     = "ifeng.manualRPM"
        static let curve         = "ifeng.curve"
        static let menuShowRPM   = "ifeng.menuShowRPM"
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
        if d.object(forKey: Keys.smoothEnabled) != nil { smoothEnabled = d.bool(forKey: Keys.smoothEnabled) }
        if d.object(forKey: Keys.smoothRate) != nil { smoothRate = d.double(forKey: Keys.smoothRate) }
        loadCurve()

        helperReady = Helper.helperReady

        if mode == .auto {
            ioQueue.async { Helper.restoreAuto() }
        }

        refresh()
        updater.bootstrap()

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

    var primaryRPM: Double { fans.first?.ac ?? 0 }

    var sliderRange: ClosedRange<Double> {
        let mn = fans.first?.mn ?? 1200
        let mx = fans.first?.mx ?? 6200
        return mn...max(mn + 200, mx)
    }

    var isForcing: Bool { fans.contains { $0.md != 0 } }

    /// 菜单栏文本：温度必显，转速可选
    var menuBarText: String {
        let t = maxTemp.map { String(format: "%.0f°", $0) } ?? "--°"
        if menuShowRPM, primaryRPM > 0 {
            return "\(t) \(Int(primaryRPM.rounded()))"
        }
        return t
    }

    var targetDeviation: Double? {
        guard let t = maxTemp else { return nil }
        return t - targetTemp
    }

    var curveRPM: Double { rpmFor(temp: maxTemp ?? targetTemp) }

    var statusColorHint: String {
        guard let t = maxTemp else { return "" }
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
        smoothEnabled && pendingTarget > 0 && abs(pendingTarget - lastWrittenRPM) >= 15
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

    private func desiredRPM(advance: Bool = true) -> Double {
        switch mode {
        case .auto:
            return 0
        case .manual:
            return clamp(manualRPM)
        case .curve:
            return rpmFor(temp: maxTemp ?? targetTemp)
        case .target:
            return loopTarget(advance: advance)
        }
    }

    /// 恒温闭环：以目标温度为设定值，按误差比例增减转速
    private func loopTarget(advance: Bool = true) -> Double {
        let r = sliderRange
        guard let t = maxTemp else { return clamp(manualRPM) }

        if t >= 95 { return r.upperBound }

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

    /// 按当前模式把目标下发；开启平滑时由 rampStep 逐步逼近
    func applyNow() {
        guard mode != .auto else { return }
        let target = desiredRPM(advance: false)
        pendingTarget = target

        if smoothEnabled {
            if rampRPM < 0 { rampRPM = lastWrittenRPM > 0 ? lastWrittenRPM : target }
        } else {
            writeAllAsync(target)
        }
    }

    private func enforcePolicy() {
        guard mode != .auto, !fans.isEmpty else { return }

        // 首次进入非自动模式时，以风扇当前实际转速为平滑起点，避免一上来就跳变
        if lastWrittenRPM < 0, let f = fans.first {
            lastWrittenRPM = f.tg > 0 ? f.tg : f.ac
        }

        let target = desiredRPM(advance: true)
        pendingTarget = target

        guard !smoothEnabled else {
            if rampRPM < 0 { rampRPM = lastWrittenRPM > 0 ? lastWrittenRPM : target }
            return
        }

        let stale = Date().timeIntervalSince(lastApplyTime) > 25
        if abs(target - lastWrittenRPM) >= 60 || stale || !isForcing {
            writeAllAsync(target)
        }
    }

    /// 平滑推进：每个 0.25 秒节拍最多走 rate × dt 转
    private func rampStep() {
        guard pendingTarget > 0, !fans.isEmpty else { return }
        if rampRPM < 0 { rampRPM = lastWrittenRPM > 0 ? lastWrittenRPM : pendingTarget }

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

        guard abs(next - lastWrittenRPM) >= 15 else { return }
        writeAllAsync(next)
    }

    /// 关闭平滑时把目标一次性写下去
    private func flushSmooth() {
        guard pendingTarget > 0 else { return }
        rampRPM = pendingTarget
        writeAllAsync(pendingTarget)
    }

    private func writeAllAsync(_ rpm: Double) {
        let list = fans
        lastWrittenRPM = rpm
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
