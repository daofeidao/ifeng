import SwiftUI
import AppKit

struct ContentView: View {

    @ObservedObject var model: FanModel
    @ObservedObject var updater: Updater

    @State private var tab: Int = 0
    @State private var tabInitialized = false
    @State private var sliderRPM: Double = 3000
    @State private var showAllTemps = true
    @State private var dragID: UUID? = nil

    /// 面板高度按页签收紧：内容矮的页不留「下巴」
    private var panelHeight: CGFloat {
        switch tab {
        case 0:  return showAllTemps ? 620 : 500   // 定速：传感器全显时最高
        case 1:  return 620                         // 曲线：图表 + 节点列表
        case 2:  return 505                         // 控温
        default: return 480                         // 我的
        }
    }

    /// 启动时按持久化的模式选择初始页签
    private static func initialTab(for mode: FanMode) -> Int {
        switch mode {
        case .manual: return 0
        case .curve:  return 1
        case .target: return 2
        case .auto:   return 1
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            Divider()
            Group {
                switch tab {
                case 0:  speedTab
                case 1:  curveTab
                case 2:  tempTab
                default: mineTab
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 372, height: panelHeight)
        .animation(.easeOut(duration: 0.15), value: tab)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if !tabInitialized {
                tabInitialized = true
                tab = Self.initialTab(for: model.mode)   // 启动时落在当前模式对应的页签
            }
            syncSlider()
            updater.checkIfStale()
        }
        .onChange(of: model.mode) { _ in syncSlider() }
        .onChange(of: model.fans.count) { _ in syncSlider() }
    }

    // MARK: - 顶部

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "fanblades.fill")
                    .font(.system(size: 15))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 0) {
                    Text("风扇控制")
                        .font(.system(size: 13, weight: .semibold))
                    Text("iFeng \(AppInfo.version) · \(model.mode.title)")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if updater.readyToInstall {
                    Button {
                        tab = 3
                    } label: {
                        Text("可更新")
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.16))
                            .foregroundColor(.green)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
            }
            tempStrip
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var tempStrip: some View {
        HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(tempText)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(statusColor)
                Text("°C")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(model.controlSensorName)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Text(model.statusColorHint)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(statusColor)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(Int(model.displayRPM.rounded())) RPM")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(rpmStatusColor)
                if model.isRamping {
                    Text("过渡中")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.blue)
                } else if model.isForcing {
                    Text("已接管")
                        .font(.system(size: 8))
                        .foregroundColor(.orange)
                } else {
                    Text("系统自动")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var statusColor: Color {
        guard let t = model.controlTemp else { return .gray }
        if t >= 90 { return .red }
        if t >= 78 { return .orange }
        if t <= 55 { return .blue }
        return .green
    }

    /// 转速按占满速的比例变色：低=蓝（安静）→ 绿 → 橙 → 红（满速）
    private var rpmStatusColor: Color {
        let v = model.displayRPM
        guard model.fanMax > 100, v > 1 else { return .secondary }
        let r = v / model.fanMax
        if r >= 0.95 { return .red }
        if r >= 0.75 { return .orange }
        if r <= 0.35 { return .blue }
        return .green
    }

    private var tempText: String {
        guard let t = model.controlTemp else { return "--" }
        return String(format: "%.0f", t)
    }

    // MARK: - 页签

    private var tabBar: some View {
        HStack(spacing: 4) {
            tabButton(0, "定速")
            tabButton(1, "曲线")
            tabButton(2, "控温")
            tabButton(3, "我的")
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private func tabButton(_ idx: Int, _ title: String) -> some View {
        // 选中态 = 蓝色圆角背景（样式沿用最初的版本）。
        // 但不用 Button 实现：按钮点击后会拿到键盘焦点，macOS 会画一圈蓝色焦点框，
        // 且面板打开时首个按钮自动获得焦点 —— 这就是之前「定速」上那个去不掉的框。
        // 改成纯视图 + onTapGesture，样式归样式，焦点圈彻底消失。
        Text(title)
            .font(.system(size: 11, weight: tab == idx ? .semibold : .regular))
            .foregroundColor(tab == idx ? Color.white : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(tab == idx ? Color.accentColor : Color.clear)
                )
            .contentShape(Rectangle())
            .onTapGesture { selectTab(idx) }
    }

    private func selectTab(_ idx: Int) {
        tab = idx
        switch idx {
        case 0: if model.mode != .manual { model.mode = .manual }
        case 1: if model.mode != .curve && model.mode != .auto { model.mode = .curve }
        case 2: if model.mode != .target { model.mode = .target }
        default: break
        }
    }

    // MARK: - 定速

    private var speedTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("固定转速")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(sliderRPM.rounded()))")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(rpmStatusColor)
                Text("RPM")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            SpeedSlider(value: $sliderRPM, maxValue: model.fanMax) { editing in
                if model.mode != .manual { model.mode = .manual }
                model.manualRPM = sliderRPM
                if !editing { model.applyNow() }
            }

            speedQuickRow

            Divider()

            fanDetail

            Divider()

            tempSection
        }
    }

    private var quickSpeeds: [Double] {
        var list: [Double] = [0, 2000, 3500, 5000]
        if model.fanMax > 5500 { list.append(model.fanMax) }
        return list
    }

    private var speedQuickRow: some View {
        HStack(spacing: 6) {
            ForEach(quickSpeeds, id: \.self) { v in
                // 同页签：不用 Button，避免点击后的蓝色焦点圈
                let selected = Int(sliderRPM.rounded()) == Int(v)
                Text(v <= 0 ? "0" : "\(Int(v))")
                    .font(.system(size: 10, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? Color.accentColor : Color.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.gray.opacity(selected ? 0.18 : 0.10))
                    )
                    .contentShape(Capsule())
                    .onTapGesture {
                        sliderRPM = v
                        model.manualRPM = v
                        if model.mode != .manual { model.mode = .manual }
                        model.applyNow()
                    }
            }
            Spacer()
        }
    }

    // MARK: - 曲线

    private var sortedCurve: [CurvePoint] {
        model.curve.sorted { $0.temp < $1.temp }
    }

    private var curveTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            presetRow

            if model.mode == .auto {
                Text("当前由系统固件控温，虚线为固件默认曲线（示意）。点 1 / 2 / 3 即可接管。")
                    .font(.system(size: 9))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            graph

            hintRow

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(sortedCurve) { pt in
                        curveRow(pt)
                    }
                }
            }
            .frame(maxHeight: 156)

            Spacer(minLength: 0)
        }
    }

    private var presetRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                presetButton(1, "1 静音")
                presetButton(2, "2 均衡")
                presetButton(3, "3 性能")
            }
            HStack(spacing: 6) {
                Button("系统自动") { model.restoreAuto() }
                    .controlSize(.mini)
                Button("加节点") { model.addCurvePoint() }
                    .controlSize(.mini)
                Button("恢复默认") {
                    model.resetCurve()
                    if model.mode == .curve { model.applyNow() }
                }
                .controlSize(.mini)
                Spacer()
            }
        }
    }

    private func presetButton(_ level: Int, _ title: String) -> some View {
        Button {
            model.applyPreset(level)
        } label: {
            Text(title)
                .font(.system(size: 10, weight: model.presetLevel == level ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(model.presetLevel == level
                              ? Color.accentColor.opacity(0.16)
                              : Color.gray.opacity(0.10))
                )
                .foregroundColor(model.presetLevel == level ? Color.accentColor : Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var hintRow: some View {
        HStack {
            Text("拖动圆点：左右改温度，上下改转速")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            Spacer()
            Text("\(model.curve.count) 节点")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
    }

    private func curveRow(_ pt: CurvePoint) -> some View {
        HStack(spacing: 6) {
            Stepper(value: Binding(get: { pt.temp },
                                   set: { v in
                                       model.updatePoint(pt.id, temp: v)
                                       model.applyNow()
                                   }),
                    in: 30...105, step: 1) {
                Text("\(Int(pt.temp)) °C")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .frame(width: 46, alignment: .leading)
            }
            .controlSize(.mini)

            Stepper(value: Binding(get: { pt.rpm },
                                   set: { v in
                                       model.updatePoint(pt.id, rpm: v)
                                       model.applyNow()
                                   }),
                    in: model.sliderRange, step: 100) {
                Text("\(Int(pt.rpm)) RPM")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .frame(width: 66, alignment: .leading)
            }
            .controlSize(.mini)

            Spacer(minLength: 0)

            Button {
                model.removePoint(pt.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            .disabled(model.curve.count <= 2)
        }
        .padding(.vertical, 1)
    }

    private var draggedPoint: CurvePoint? {
        guard let id = dragID else { return nil }
        return model.curve.first { $0.id == id }
    }

    private var graph: some View {
        let pts = sortedCurve
        let sys = model.systemCurvePoints
        let r = model.sliderRange
        return GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                Path { p in
                    for i in 0...4 {
                        let y = h * CGFloat(i) / 4.0
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: w, y: y))
                    }
                }
                .stroke(Color.gray.opacity(0.16), lineWidth: 0.5)

                // 系统固件默认曲线（参考）
                Path { p in
                    for (i, pt) in sys.enumerated() {
                        let point = CGPoint(x: px(pt.temp, w), y: py(pt.rpm, h, r))
                        if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
                    }
                }
                .stroke(Color.gray.opacity(model.mode == .auto ? 0.75 : 0.35),
                        style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))

                if let t = model.controlTemp {
                    Path { p in
                        let x = px(t, w)
                        p.move(to: CGPoint(x: x, y: 0))
                        p.addLine(to: CGPoint(x: x, y: h))
                    }
                    .stroke(Color.red.opacity(0.35),
                            style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }

                Path { p in
                    for (i, pt) in pts.enumerated() {
                        let point = CGPoint(x: px(pt.temp, w), y: py(pt.rpm, h, r))
                        if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
                    }
                }
                .stroke(Color.accentColor.opacity(model.mode == .auto ? 0.45 : 1),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                ForEach(pts) { pt in
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: dragID == pt.id ? 18 : 13,
                               height: dragID == pt.id ? 18 : 13)
                        .overlay(
                            Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5)
                        )
                        .position(x: px(pt.temp, w), y: py(pt.rpm, h, r))
                }

                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                handleDrag(value.location, size: geo.size)
                            }
                            .onEnded { _ in
                                dragID = nil
                                if model.mode == .curve { model.applyNow() }
                            }
                    )

                if let dp = draggedPoint {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(Int(dp.temp)) °C")
                            .font(.system(size: 9, weight: .medium))
                            .monospacedDigit()
                        Text("\(Int(dp.rpm)) RPM")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(4)
                    .padding(4)
                }
            }
        }
        .frame(height: 168)
        .background(Color.gray.opacity(0.07))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.gray.opacity(0.15), lineWidth: 0.5)
        )
    }

    // MARK: 拖动计算

    private func handleDrag(_ loc: CGPoint, size: CGSize) {
        let pts = sortedCurve
        guard !pts.isEmpty, size.width > 1, size.height > 1 else { return }
        let r = model.sliderRange

        if dragID == nil {
            var bestID: UUID? = nil
            var bestDist: CGFloat = 2200    // 约 47pt 半径的平方
            for p in pts {
                let dx = px(p.temp, size.width) - loc.x
                let dy = py(p.rpm, size.height, r) - loc.y
                let d = dx * dx + dy * dy
                if d <= bestDist {
                    bestDist = d
                    bestID = p.id
                }
            }
            guard bestID != nil else { return }
            dragID = bestID
        }

        guard let id = dragID else { return }
        model.updatePoint(id,
                          temp: tempAt(loc.x, size.width),
                          rpm: rpmAt(loc.y, size.height, r))
    }

    /// 曲线图内边距：圆点半径 9pt（拖动时 18pt），不加内边距的话
    /// 最高/最低转速与边缘温度的圆点会被图框裁掉一半
    private static let graphInset: CGFloat = 12

    private func tempAt(_ x: CGFloat, _ w: CGFloat) -> Double {
        let inner = max(1, w - Self.graphInset * 2)
        let ratio = Double(min(max((x - Self.graphInset) / inner, 0), 1))
        return 30.0 + ratio * 75.0
    }

    private func rpmAt(_ y: CGFloat, _ h: CGFloat, _ r: ClosedRange<Double>) -> Double {
        let inner = max(1, h - Self.graphInset * 2)
        let ratio = 1.0 - Double(min(max((y - Self.graphInset) / inner, 0), 1))
        return r.lowerBound + ratio * (r.upperBound - r.lowerBound)
    }

    private func px(_ temp: Double, _ w: CGFloat) -> CGFloat {
        let inner = max(1, w - Self.graphInset * 2)
        let v = (min(max(temp, 30), 105) - 30) / 75.0
        return Self.graphInset + CGFloat(v) * inner
    }

    private func py(_ rpm: Double, _ h: CGFloat, _ r: ClosedRange<Double>) -> CGFloat {
        let inner = max(1, h - Self.graphInset * 2)
        let span = max(1.0, r.upperBound - r.lowerBound)
        let v = (min(max(rpm, r.lowerBound), r.upperBound) - r.lowerBound) / span
        return Self.graphInset + (1 - CGFloat(v)) * inner
    }

    // MARK: - 控温

    private var tempTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("目标温度")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.0f", model.targetTemp))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(statusColor)
                Text("°C")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Slider(value: Binding(get: { model.targetTemp },
                                  set: { model.targetTemp = $0 }),
                   in: 45...90, step: 1,
                   onEditingChanged: { editing in
                       if !editing { model.applyNow() }
                   })

            HStack {
                Text("45").font(.system(size: 8)).foregroundColor(.secondary)
                Spacer()
                Text("90").font(.system(size: 8)).foregroundColor(.secondary)
            }

            deviationRow

            Divider()

            fanDetail

            Divider()

            tempSection
        }
    }

    private var deviationRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("当前温度")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
                if let d = model.targetDeviation {
                    Text(String(format: "%+.1f °C", d))
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(abs(d) <= 1.5 ? .green : (d > 0 ? .orange : .blue))
                    Text(loopHint(d))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                } else {
                    Text("--")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            Text("控制量取 \(model.controlSensorKey)（\(model.controlSensorName)），可在下方传感器列表点「设控制」更换。")
                .font(.system(size: 9))
                .foregroundColor(Color.gray.opacity(0.85))
        }
    }

    private func loopHint(_ d: Double) -> String {
        if d > 1.5 { return "升温中，加速" }
        if d < -1.5 { return "已达标，减速" }
        return "稳定"
    }

    // MARK: - 我的

    private var mineTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                versionBlock
                Divider()
                statusBarSection
                Divider()
                autostartRow
                settingsFooter
            }
        }
    }

    private var versionBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("版本")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text(AppInfo.version)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                Text(updater.message)
                    .font(.system(size: 9))
                    .foregroundColor(updater.readyToInstall ? .green : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
            }

            HStack(spacing: 5) {
                Text("作者：\(AppInfo.author)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Button {
                    NSWorkspace.shared.open(AppInfo.repoURL)
                } label: {
                    Text("GitHub")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.accentColor)
                        .underline()
                }
                .buttonStyle(.plain)
                .help("在浏览器中打开项目主页")
                Spacer()
                Text("自动更新")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Toggle("", isOn: Binding(get: { updater.autoUpdate },
                                        set: { updater.autoUpdate = $0 }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                Button(updater.checking ? "检查中…" : "检查更新") {
                    updater.check()
                }
                .controlSize(.mini)
                .disabled(updater.checking || updater.downloading)
            }

            if let err = updater.lastError {
                Text(err)
                    .font(.system(size: 9))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if updater.readyToInstall {
                HStack(spacing: 8) {
                    Button("重启并安装") { updater.installStaged() }
                        .controlSize(.small)
                    Button("打开下载页") { updater.openReleasePage() }
                        .controlSize(.small)
                    Spacer()
                }
            } else if updater.lastError != nil {
                Button("打开下载页") { updater.openReleasePage() }
                    .controlSize(.mini)
            }
        }
    }

    // MARK: - 状态栏显示项

    private var statusBarSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("状态栏显示")
                .font(.system(size: 10, weight: .medium))

            // 四个开关并列一行，节省面板高度
            HStack(spacing: 12) {
                statusToggle("网速", Binding(get: { model.menuShowNet },
                                            set: { model.menuShowNet = $0 }))
                statusToggle("温度", Binding(get: { model.menuShowTemp },
                                            set: { model.menuShowTemp = $0 }))
                statusToggle("转速", Binding(get: { model.menuShowRPM },
                                            set: { model.menuShowRPM = $0 }))
                statusToggle("平滑", Binding(get: { model.smoothEnabled },
                                            set: { model.smoothEnabled = $0 }))
                Spacer()
            }

            if model.smoothEnabled {
                HStack(spacing: 6) {
                    Text("速率")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Slider(value: Binding(get: { model.smoothRate },
                                          set: { model.smoothRate = $0 }),
                           in: 100...1500, step: 50)
                    Text("\(Int(model.smoothRate))")
                        .font(.system(size: 9, weight: .medium))
                        .monospacedDigit()
                        .frame(width: 34, alignment: .trailing)
                }
            }

            unitRow("网速单位", selection: Binding(get: { model.netUnit },
                                                 set: { model.netUnit = $0 }),
                    cases: NetUnit.allCases.map { ($0.title, $0) })

            unitRow("风速单位", selection: Binding(get: { model.fanUnit },
                                                 set: { model.fanUnit = $0 }),
                    cases: FanUnit.allCases.map { ($0.title, $0) })
        }
    }

    private func statusToggle(_ title: String, _ binding: Binding<Bool>) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10))
            Toggle("", isOn: binding)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
    }

    private func unitRow<T: Hashable & Identifiable>(_ title: String,
                                                     selection: Binding<T>,
                                                     cases: [(String, T)]) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            Picker("", selection: selection) {
                ForEach(cases, id: \.1) { item in
                    Text(item.0).tag(item.1)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.mini)
            .labelsHidden()
            Spacer()
        }
    }

    private var autostartRow: some View {
        Toggle(isOn: Binding(get: { model.autostartEnabled },
                             set: { model.toggleAutostart($0) })) {
            VStack(alignment: .leading, spacing: 1) {
                Text("开机自动启动").font(.system(size: 11))
                Text("登录后自动运行，写入登录项")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }

    // MARK: - 我的页尾部

    @ViewBuilder
    private var settingsFooter: some View {
        Divider()

        VStack(alignment: .leading, spacing: 4) {
            infoRow("辅助工具", model.helperReady ? "正常" : "未启用")
            infoRow("风扇数量", "\(model.fans.count)")
            infoRow("控制状态", model.isForcing ? "已接管（强制）" : "系统自动")
            infoRow("当前模式", model.mode.title)
        }

        if !model.helperReady {
            Button("一键启用风扇写入（弹一次密码框）") {
                model.requestHelperInstall()
            }
            .controlSize(.small)
        }

        if !model.helperReady, let err = model.lastError {
            Text(err)
                .font(.system(size: 9))
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        Divider()

        HStack(spacing: 8) {
            Button("恢复系统自动") { model.restoreAuto() }
                .controlSize(.small)
            Spacer()
            // 退出做成醒目的红底白字大按钮（同样不用 Button，避免焦点圈）
            Text("退 出")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.red))
                .contentShape(Capsule())
                .onTapGesture { model.quitSafely() }
        }

        Text("退出或注销时会把风扇交还系统固件。若被强制结束进程，风扇会停在最后转速，重新打开后点「恢复系统自动」即可。")
            .font(.system(size: 9))
            .foregroundColor(Color.gray.opacity(0.85))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func infoRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .medium))
        }
    }

    // MARK: - 风扇与传感器

    private var fanDetail: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.fans.isEmpty {
                Text("未检测到风扇")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                ForEach(model.fans, id: \.i) { fan in
                    HStack(spacing: 8) {
                        Text("风扇 \(fan.i + 1)")
                            .font(.system(size: 11, weight: .medium))
                        Text(String(format: "%.0f – %.0f", fan.mn, fan.mx))
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(String(format: "目标 %.0f", fan.tg))
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                        if model.isRamping, model.writtenRPM >= 0 {
                            Text(String(format: "写入 %.0f", model.writtenRPM))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.blue)
                                .monospacedDigit()
                        }
                        Text(fan.md != 0 ? "强制" : "自动")
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(fan.md != 0 ? Color.orange.opacity(0.18)
                                                    : Color.gray.opacity(0.14))
                            .foregroundColor(fan.md != 0 ? .orange : .secondary)
                            .cornerRadius(3)
                    }
                }
            }
        }
    }

    private var visibleTemps: [FStatus.T] {
        let sorted = model.temps.sorted { $0.v > $1.v }
        guard !showAllTemps else { return sorted }
        var list = Array(sorted.prefix(4))
        if let ctl = model.temps.first(where: { $0.k == "TC0P" }),
           !list.contains(where: { $0.id == ctl.id }) {
            list.append(ctl)
        }
        return list
    }

    private var tempSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("温度传感器")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                if model.temps.count > 4 {
                    Button(showAllTemps ? "收起" : "全部 \(model.temps.count) 项") {
                        showAllTemps.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundColor(.accentColor)
                }
            }
            ForEach(visibleTemps) { t in
                HStack(spacing: 6) {
                    Text(t.n)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                    // 点击把该传感器设为控制量（恒温/曲线/状态栏温度都跟着它走）
                    let selected = t.k == model.controlSensorKey
                    Text(selected ? "控制中" : "设控制")
                        .font(.system(size: 8, weight: selected ? .semibold : .regular))
                        .foregroundColor(selected ? Color.white : Color.accentColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule().fill(selected ? Color.accentColor
                                                    : Color.accentColor.opacity(0.12))
                        )
                        .contentShape(Capsule())
                        .onTapGesture { model.controlSensorKey = t.k }
                    Text(t.k)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(Color.gray.opacity(0.65))
                    Text(String(format: "%.1f °C", t.v))
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(t.v >= 90 ? Color.red
                                         : t.v >= 78 ? Color.orange
                                         : t.v <= 45 ? Color.blue
                                         : Color.primary)
                        .frame(width: 56, alignment: .trailing)
                }
            }
        }
    }

    // MARK: - 同步

    private func syncSlider() {
        if let tg = model.fans.first?.tg, tg > 0 {
            sliderRPM = min(max(tg, model.sliderRange.lowerBound), model.sliderRange.upperBound)
        } else {
            sliderRPM = model.manualRPM
        }
    }
}

// MARK: - 定速滑杆

/// 实心圆柱（白色）+ 刻度 + 无极变速。
/// 拖动过程中只改显示值与 model.manualRPM，松手才下发，避免每像素写一次 SMC。
struct SpeedSlider: View {

    @Binding var value: Double
    let maxValue: Double
    var onEditing: (Bool) -> Void

    private let knob: CGFloat = 20
    private let trackH: CGFloat = 14

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { geo in
                let w = geo.size.width
                let usable = max(1, w - knob)
                let ratio = CGFloat(min(max(value, 0), maxValue) / max(maxValue, 1))
                let cx = knob / 2 + usable * ratio

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white)
                        .overlay(Capsule().stroke(Color.gray.opacity(0.30), lineWidth: 1))
                        .frame(height: trackH)

                    Capsule()
                        .fill(Color.accentColor.opacity(0.85))
                        .frame(width: max(trackH, cx), height: trackH)

                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(Color.gray.opacity(0.35), lineWidth: 1))
                        .shadow(color: Color.black.opacity(0.18), radius: 2, y: 1)
                        .frame(width: knob, height: knob)
                        .offset(x: cx - knob / 2)
                }
                .frame(width: w, height: knob)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let px = min(max(g.location.x - knob / 2, 0), usable)
                            let v = Double(px / usable) * maxValue
                            value = min(max(v.rounded(), 0), maxValue)
                            onEditing(true)
                        }
                        .onEnded { _ in onEditing(false) }
                )
            }
            .frame(height: knob)

            tickRow
        }
    }

    private var tickRow: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let usable = max(1, w - knob)
            let step: Double = 1000
            let count = Int(maxValue / step)

            ZStack(alignment: .topLeading) {
                ForEach(0...count, id: \.self) { i in
                    let v = Double(i) * step
                    let x = knob / 2 + usable * CGFloat(v / max(maxValue, 1))
                    VStack(spacing: 1) {
                        Rectangle()
                            .fill(Color.gray.opacity(0.45))
                            .frame(width: 1, height: 4)
                        Text("\(Int(v))")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                            .fixedSize()
                    }
                    .position(x: min(max(x, 12), w - 12), y: 9)
                }
            }
        }
        .frame(height: 26)
    }
}
