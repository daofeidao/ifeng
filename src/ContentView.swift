import SwiftUI
import AppKit

struct ContentView: View {

    @ObservedObject var model: FanModel
    @ObservedObject var updater: Updater

    @State private var tab: Int = 0
    @State private var sliderRPM: Double = 3000
    @State private var showAllTemps = false
    @State private var dragID: UUID? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            Divider()
            Group {
                switch tab {
                case 0:  controlTab
                case 1:  curveTab
                default: settingsTab
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 360, height: 588)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
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
                    Text("iFeng \(AppInfo.version)")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if updater.readyToInstall {
                    Button {
                        tab = 2
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
                if model.isRamping {
                    Text("过渡中")
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.14))
                        .foregroundColor(.blue)
                        .cornerRadius(4)
                }
                Text(model.statusColorHint)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(statusColor.opacity(0.15))
                    .foregroundColor(statusColor)
                    .cornerRadius(4)
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("最高温度")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(tempText)
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("°C")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text("风扇转速")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(Int(model.primaryRPM.rounded()))")
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("RPM")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var statusColor: Color {
        guard let t = model.controlTemp else { return .gray }
        if t >= 90 { return .red }
        if t >= 78 { return .orange }
        if t <= 55 { return .blue }
        return .green
    }

    private var tempText: String {
        guard let t = model.controlTemp else { return "--" }
        return String(format: "%.0f", t)
    }

    private var tabBar: some View {
        Picker("", selection: $tab) {
            Text("控制").tag(0)
            Text("曲线").tag(1)
            Text("设置").tag(2)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    // MARK: - 控制页

    private var controlTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: Binding(get: { model.mode }, set: { model.mode = $0 })) {
                ForEach(FanMode.allCases) { m in
                    Text(m.title).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(model.mode.detail)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            modeControls

            Divider()

            fanDetail

            Divider()

            tempSection
        }
    }

    @ViewBuilder
    private var modeControls: some View {
        switch model.mode {
        case .auto:
            EmptyView()

        case .target:
            VStack(spacing: 6) {
                HStack {
                    Text("目标温度")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.0f °C", model.targetTemp))
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                }
                Slider(value: Binding(get: { model.targetTemp },
                                      set: { model.targetTemp = $0 }),
                       in: 45...90, step: 1)

                HStack {
                    Text("当前温度")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    if let d = model.targetDeviation {
                        Text(String(format: "%+.1f °C", d))
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundColor(abs(d) <= 1.5 ? .green : (d > 0 ? .orange : .blue))
                        Text(loopHint(d))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    } else {
                        Text("--").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                }
            }

        case .curve:
            VStack(spacing: 6) {
                HStack {
                    Text("当前温度对应转速")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(model.curveRPM.rounded())) RPM")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                }
                Button("编辑曲线（\(model.curve.count) 个节点）") {
                    tab = 1
                }
                .controlSize(.small)
            }

        case .manual:
            VStack(spacing: 6) {
                HStack {
                    Text("固定转速")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(sliderRPM.rounded())) RPM")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                }
                Slider(value: $sliderRPM, in: model.sliderRange, step: 25,
                       onEditingChanged: { editing in
                           if !editing {
                               model.manualRPM = sliderRPM
                               model.applyNow()
                           }
                       })
            }
        }
    }

    private func loopHint(_ d: Double) -> String {
        if d > 1.5 { return "升温中，加速" }
        if d < -1.5 { return "已达标，减速" }
        return "稳定"
    }

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
        var list = Array(sorted.prefix(5))
        // 控制用的传感器（TC0P）必须始终可见，哪怕它的温度不排在前 5
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
                if model.temps.count > 5 {
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
                    if t.k == "TC0P" {
                        Text("控制")
                            .font(.system(size: 8))
                            .foregroundColor(.accentColor)
                    }
                    Text(t.k)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(Color.gray.opacity(0.65))
                    Text(String(format: "%.1f °C", t.v))
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }
            }
        }
    }

    // MARK: - 曲线页

    private var sortedCurve: [CurvePoint] {
        model.curve.sorted { $0.temp < $1.temp }
    }

    private var curveTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            graph

            Text("拖动圆点直接调整：左右改温度，上下改转速。")
                .font(.system(size: 9))
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                Button("添加节点") { model.addCurvePoint() }
                    .controlSize(.mini)
                Button("恢复默认") { model.resetCurve() }
                    .controlSize(.mini)
                Spacer()
                Text("30 – 105 °C，≥95 °C 全速")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(sortedCurve) { pt in
                        curveRow(pt)
                    }
                }
            }
            .frame(maxHeight: 196)

            Spacer(minLength: 0)
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
                .stroke(Color.accentColor,
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
        .frame(height: 172)
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
            var bestDist: CGFloat = 2200    // 约 47pt 半径的平方，容错更大
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

    private func tempAt(_ x: CGFloat, _ w: CGFloat) -> Double {
        let ratio = Double(min(max(x / max(w, 1), 0), 1))
        return 30.0 + ratio * 75.0      // 30 – 105 °C
    }

    private func rpmAt(_ y: CGFloat, _ h: CGFloat, _ r: ClosedRange<Double>) -> Double {
        let ratio = 1.0 - Double(min(max(y / max(h, 1), 0), 1))
        return r.lowerBound + ratio * (r.upperBound - r.lowerBound)
    }

    private func px(_ temp: Double, _ w: CGFloat) -> CGFloat {
        let v = (min(max(temp, 30), 105) - 30) / 75.0
        return CGFloat(v) * w
    }

    private func py(_ rpm: Double, _ h: CGFloat, _ r: ClosedRange<Double>) -> CGFloat {
        let span = max(1.0, r.upperBound - r.lowerBound)
        let v = (min(max(rpm, r.lowerBound), r.upperBound) - r.lowerBound) / span
        return h - CGFloat(v) * h
    }

    // MARK: - 设置页

    private var settingsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {

                // 平滑过渡
                VStack(alignment: .leading, spacing: 7) {
                    Toggle(isOn: Binding(get: { model.smoothEnabled },
                                         set: { model.smoothEnabled = $0 })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("转速平滑过渡").font(.system(size: 11))
                            Text("目标转速变化时逐步升降，避免风扇突然变速")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)

                    if model.smoothEnabled {
                        HStack {
                            Text("过渡速率")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(Int(model.smoothRate)) RPM/秒")
                                .font(.system(size: 10, weight: .medium))
                                .monospacedDigit()
                        }
                        Slider(value: Binding(get: { model.smoothRate },
                                              set: { model.smoothRate = $0 }),
                               in: 100...1500, step: 50)

                        HStack(spacing: 6) {
                            Button("慢 250") { model.smoothRate = 250 }
                                .controlSize(.mini)
                            Button("标准 500") { model.smoothRate = 500 }
                                .controlSize(.mini)
                            Button("快 1000") { model.smoothRate = 1000 }
                                .controlSize(.mini)
                            Spacer()
                        }

                        Text(model.smoothTimeHint)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }

                Divider()

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

                statusBarSection

                Divider()

                // 版本与更新
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("版本")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text(AppInfo.version)
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                        Spacer()
                        Button(updater.checking ? "检查中…" : "检查更新") {
                            updater.check()
                        }
                        .controlSize(.mini)
                        .disabled(updater.checking || updater.downloading)
                    }

                    Toggle(isOn: Binding(get: { updater.autoUpdate },
                                         set: { updater.autoUpdate = $0 })) {
                        Text("自动检查并后台下载更新")
                            .font(.system(size: 10))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)

                    Text(updater.message)
                        .font(.system(size: 9))
                        .foregroundColor(updater.readyToInstall ? .green : .secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let err = updater.lastError {
                        Text(err)
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("打开下载页") { updater.openReleasePage() }
                            .controlSize(.mini)
                    }

                    if updater.readyToInstall {
                        HStack(spacing: 8) {
                            Button("重启并安装") { updater.installStaged() }
                                .controlSize(.small)
                            Button("打开下载页") { updater.openReleasePage() }
                                .controlSize(.small)
                            Spacer()
                        }
                    }
                }

                settingsFooter
            }
        }
    }

    // MARK: - 状态栏显示项

    private var statusBarSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("状态栏显示")
                .font(.system(size: 10, weight: .medium))

            Toggle(isOn: Binding(get: { model.menuShowRPM },
                                 set: { model.menuShowRPM = $0 })) {
                Text("风扇转速").font(.system(size: 10))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            Toggle(isOn: Binding(get: { model.menuShowNet },
                                 set: { model.menuShowNet = $0 })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("网络速率").font(.system(size: 10))
                    Text("显示在风扇图标左侧，宽度固定不抖动")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            HStack(spacing: 6) {
                Text("单位")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Picker("", selection: Binding(get: { model.netUnit },
                                              set: { model.netUnit = $0 })) {
                    ForEach(NetUnit.allCases) { u in
                        Text(u.title).tag(u)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .frame(width: 168)
                Spacer()
            }

            HStack(spacing: 4) {
                Text("当前")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Text(model.netText)
                    .font(.system(size: 9, weight: .medium))
                    .monospacedDigit()
                Spacer()
            }
        }
    }

    // MARK: - 设置页尾部（拆出，避免单个 ViewBuilder 超过 10 个子视图）

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

        Divider()

        HStack(spacing: 8) {
            Button("恢复系统自动") { model.restoreAuto() }
                .controlSize(.small)
            Spacer()
            Button("退出") { model.quitSafely() }
                .controlSize(.small)
        }

        if !model.helperReady, let err = model.lastError {
            Text(err)
                .font(.system(size: 9))
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
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

    // MARK: - 同步

    private func syncSlider() {
        if let tg = model.fans.first?.tg, tg > 0 {
            sliderRPM = min(max(tg, model.sliderRange.lowerBound), model.sliderRange.upperBound)
        } else {
            sliderRPM = model.manualRPM
        }
    }
}
