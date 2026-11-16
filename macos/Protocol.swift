import Foundation

struct RemoteProcess: Identifiable {
    var pid: UInt32
    var cpu: Double
    var rss: UInt64
    var start: UInt64
    var name: String
    var id: String { "\(pid)-\(start)" }
}
enum CoreKind: UInt16 { case unknown=0, performance=1, efficiency=2, offline=3 }
struct Snapshot {
    static let size = 1024
    let sequence: UInt64, timestamp: Date, interval: Double
    let cores: Int, cpu: Double, processCount: Int
    let memoryTotal: UInt64, memoryAvailable: UInt64, swapTotal: UInt64, swapFree: UInt64
    let rx: UInt64, tx: UInt64, diskRead: UInt64, diskWrite: UInt64, fsTotal: UInt64, fsAvailable: UInt64, uptime: UInt64
    let load: [Double], ready: Bool, collectMicros: UInt64, hostname: String, coreUsage: [Double]
    let user: Double, system: Double, memoryFree: UInt64, cached: UInt64, buffers: UInt64
    let coreKinds: [CoreKind]
    let performanceCores: Int, efficiencyCores: Int
    var hasHybridCores: Bool { coreKinds.contains(.performance) && coreKinds.contains(.efficiency) }
    func indices(for kind: CoreKind) -> [Int] { coreKinds.indices.filter { coreKinds[$0] == kind } }
    func usage(for kind: CoreKind) -> Double {
        let ids=indices(for:kind)
        return ids.isEmpty ? 0 : ids.reduce(0) { $0 + coreUsage[$1] } / Double(ids.count)
    }
    let topCPU: [RemoteProcess], topMemory: [RemoteProcess]
    var memoryUsed: UInt64 { memoryTotal - min(memoryAvailable, memoryTotal) }
    var memoryPercent: Double { memoryTotal == 0 ? 0 : Double(memoryUsed) / Double(memoryTotal) * 100 }
    init(_ data: Data) throws {
        let b = [UInt8](data)
        guard b.count == Self.size else { throw WireError.invalidFrame }
        func n(_ offset: Int, _ width: Int) -> UInt64 {
            var result: UInt64 = 0
            for i in 0..<width { result |= UInt64(b[offset + i]) << (i * 8) }
            return result
        }
        func string(_ offset: Int, _ length: Int) -> String {
            let bytes = b[offset..<(offset + length)].prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self).map { $0.isNewline || $0.asciiValue.map({ $0 < 32 || $0 == 127 }) == true ? " " : String($0) }.joined()
        }
        guard Array(b[0..<4]) == Array("RST1".utf8), (n(4,2) == 1 || n(4,2) == 2), n(6,2) == Self.size,
              n(344,4) <= 64, n(24,4) >= 500, n(24,4) <= 60000,
              n(32,4) <= 100000, n(28,4) > 0, n(40,8) > 0,
              n(48,8) <= n(40,8), n(64,8) <= n(56,8) else { throw WireError.invalidFrame }
        sequence=n(8,8);timestamp=Date(timeIntervalSince1970: Double(n(16,8))/1000);interval=Double(n(24,4))/1000
        cores=Int(n(28,4));cpu=Double(n(32,4))/1000;processCount=Int(n(36,4))
        memoryTotal=n(40,8);memoryAvailable=n(48,8);swapTotal=n(56,8);swapFree=n(64,8)
        rx=n(72,8);tx=n(80,8);diskRead=n(88,8);diskWrite=n(96,8);fsTotal=n(104,8);fsAvailable=n(112,8);uptime=n(120,8)
        load=(0..<3).map { Double(n(128+$0*4,4))/1000 };ready=n(140,4)&1 != 0;collectMicros=n(144,8);hostname=string(152,64)
        let version=n(4,2)
        let raw=(0..<Int(n(344,4))).map { UInt16(n(216+$0*2,2)) }
        guard raw.allSatisfy({ (version == 2 ? $0 & 0x3fff : $0) <= 10000 }),
              version == 1 || (n(380,2) <= 64 && n(382,2) <= 64) else { throw WireError.invalidFrame }
        coreUsage=raw.map { Double(version == 2 ? $0 & 0x3fff : $0)/100 }
        coreKinds=raw.map { version == 2 ? CoreKind(rawValue:$0 >> 14)! : .unknown }
        performanceCores=version == 2 ? Int(n(380,2)) : 0
        efficiencyCores=version == 2 ? Int(n(382,2)) : 0
        user=Double(n(348,4))/1000;system=Double(n(352,4))/1000;memoryFree=n(356,8);cached=n(364,8);buffers=n(372,8)
        func process(_ index: Int) -> RemoteProcess {
            let o=384+index*64
            return RemoteProcess(pid: UInt32(n(o,4)), cpu: Double(n(o+4,4))/1000, rss: n(o+8,8), start: n(o+16,8), name: string(o+24,40))
        }
        topCPU=(0..<5).map(process).filter { $0.pid != 0 }
        topMemory=(5..<10).map(process).filter { $0.pid != 0 }
    }
}
enum WireError: Error { case invalidFrame }

// TCP and SSH can split a frame at any byte; the transport never assumes read boundaries.
struct FrameDecoder {
    private var buffer = Data()
    mutating func append(_ data: Data) throws -> [Snapshot] {
        buffer.append(data)
        var frames: [Snapshot] = []
        while buffer.count >= Snapshot.size {
            frames.append(try Snapshot(Data(buffer.prefix(Snapshot.size))))
            buffer.removeFirst(Snapshot.size)
        }
        return frames
    }
}
