import Foundation
import Darwin
import Combine

/// 网络速率监控：读系统路由表里的接口字节计数，按固定间隔做差分
final class NetMonitor: ObservableObject {

    @Published private(set) var downBytesPerSec: Double = 0
    @Published private(set) var upBytesPerSec: Double = 0
    @Published private(set) var available = false

    private var lastIn: UInt64 = 0
    private var lastOut: UInt64 = 0
    private var lastTime = Date()
    private var timer: Timer?
    private var primed = false

    // MARK: 生命周期

    func start(interval: TimeInterval = 1.0) {
        guard timer == nil else { return }
        sample(force: true)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.sample(force: false)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }

    // MARK: 采样

    private func sample(force: Bool) {
        guard let (inB, outB) = NetMonitor.readCounters() else {
            available = false
            return
        }
        available = true

        let now = Date()
        let dt = now.timeIntervalSince(lastTime)
        guard primed, dt > 0.05 else {
            lastIn = inB
            lastOut = outB
            lastTime = now
            primed = true
            return
        }

        // 计数回绕/接口重置时差值为负，按 0 处理
        let dIn = inB >= lastIn ? Double(inB - lastIn) : 0
        let dOut = outB >= lastOut ? Double(outB - lastOut) : 0

        downBytesPerSec = dIn / dt
        upBytesPerSec = dOut / dt

        lastIn = inB
        lastOut = outB
        lastTime = now
    }

    private static func readCounters() -> (UInt64, UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len: Int = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return nil }

        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return nil }

        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        var offset = 0
        let hdrSize = MemoryLayout<if_msghdr>.size
        let hdr2Size = MemoryLayout<if_msghdr2>.size

        while offset + hdrSize <= len {
            var hdr = if_msghdr()
            withUnsafeMutableBytes(of: &hdr) { dst in
                buf.withUnsafeBytes { src in
                    dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[offset..<(offset + hdrSize)]))
                }
            }

            let msglen = Int(hdr.ifm_msglen)
            guard msglen > 0 else { break }

            if Int32(hdr.ifm_type) == RTM_IFINFO2 && offset + hdr2Size <= len {
                var h2 = if_msghdr2()
                withUnsafeMutableBytes(of: &h2) { dst in
                    buf.withUnsafeBytes { src in
                        dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[offset..<(offset + hdr2Size)]))
                    }
                }
                let flags = Int32(h2.ifm_flags)
                if (flags & IFF_UP) != 0 && (flags & IFF_LOOPBACK) == 0 {
                    totalIn &+= h2.ifm_data.ifi_ibytes
                    totalOut &+= h2.ifm_data.ifi_obytes
                }
            }

            offset += msglen
        }

        return (totalIn, totalOut)
    }

    // MARK: 格式化

    /// 自适应单位：不足 1 KB/s 显示 0K，其后 K / M
    static func format(_ bytesPerSec: Double) -> String {
        if bytesPerSec < 512 { return "0K" }
        let kb = bytesPerSec / 1024.0
        if kb < 1000 { return String(format: "%.0fK", kb) }
        let mb = kb / 1024.0
        if mb < 100 { return String(format: "%.1fM", mb) }
        return String(format: "%.0fM", mb)
    }

    var downText: String { NetMonitor.format(downBytesPerSec) }
    var upText: String { NetMonitor.format(upBytesPerSec) }
}
