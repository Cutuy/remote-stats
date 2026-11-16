import Foundation

@main enum ProtocolTests {
    static func main() throws {
        var frame=Data(repeating:0,count:1024)
        func put(_ o:Int,_ n:UInt64,_ width:Int) { for i in 0..<width { frame[o+i]=UInt8(truncatingIfNeeded:n >> (i*8)) } }
        frame.replaceSubrange(0..<4,with:"RST1".utf8)
        put(4,1,2);put(6,1024,2);put(8,42,8);put(24,2000,4);put(28,20,4)
        put(32,12345,4);put(40,32768,8);put(48,8192,8);put(140,1,4)
        put(344,2,4);put(216,2512,2);put(218,9978,2)
        put(384,77,4);put(388,101234,4);put(392,4096,8);put(400,999,8)
        frame.replaceSubrange(408..<411,with:"abc".utf8)
        let s=try Snapshot(frame)
        precondition(s.sequence==42 && s.cpu==12.345 && s.memoryPercent==75)
        precondition(s.coreUsage==[25.12,99.78])
        precondition(s.topCPU.count==1 && s.topCPU[0].pid==77 && s.topCPU[0].start==999)
        precondition(s.topCPU[0].cpu==101.234 && s.topCPU[0].rss==4096 && s.topCPU[0].name=="abc")
        for split in 1..<1024 {
            var decoder=FrameDecoder()
            let head=try decoder.append(frame.prefix(split))
            precondition(head.isEmpty)
            let frames=try decoder.append(frame.dropFirst(split))
            precondition(frames.count==1 && frames[0].sequence==42)
        }
        var decoder=FrameDecoder()
        let coalesced=try decoder.append(frame+frame+frame)
        precondition(coalesced.count==3)
        for offset in [0,4,6,24,28,40,344] {
            var broken=frame
            if offset==344 { broken[offset]=65 }
            else if offset==6 { broken[offset+1]=0 }
            else if offset==24 { broken[offset]=0;broken[offset+1]=0 }
            else if offset==40 { for i in 0..<8 { broken[offset+i]=0 } }
            else { broken[offset]=0 }
            do { _=try Snapshot(broken);fatalError("Accepted invalid frame at \(offset)") }
            catch WireError.invalidFrame {}
        }
        do { _=try Snapshot(frame.prefix(500));fatalError("Accepted truncated frame") }
        catch WireError.invalidFrame {}
        // Version 1 remains readable; version 2 carries class bits without losing usage.
        precondition(!s.hasHybridCores && s.coreKinds == [.unknown,.unknown])
        put(4,2,2);put(344,20,4);put(380,8,2);put(382,4,2)
        for i in 0..<20 { put(216+2*i,UInt64(i<16 ? (1<<14)|6000 : (2<<14)|2000),2) }
        let hybrid=try Snapshot(frame)
        precondition(hybrid.hasHybridCores && hybrid.performanceCores==8 && hybrid.efficiencyCores==4)
        precondition(hybrid.indices(for:.performance)==Array(0..<16))
        precondition(hybrid.indices(for:.efficiency)==Array(16..<20))
        precondition(hybrid.usage(for:.performance)==60 && hybrid.usage(for:.efficiency)==20)
        var hybridDecoder=FrameDecoder()
        let both=try hybridDecoder.append(frame+frame)
        precondition(both.count==2 && both[1].usage(for:.efficiency)==20)
        put(216,UInt64((1<<14)|10001),2)
        do { _=try Snapshot(frame);fatalError("Accepted out-of-range tagged CPU usage") }
        catch WireError.invalidFrame {}
        if CommandLine.arguments.count>1 {
            let actual=try Snapshot(Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
            precondition(actual.cores>0 && actual.ready && actual.topMemory.count==5)
            print("Live C → Swift: \(actual.performanceCores)P + \(actual.efficiencyCores)E, \(actual.hostname), \(actual.cores) CPUs, \(actual.cpu)% CPU, collection \(actual.collectMicros)µs")
        }
        print("Protocol tests passed: every split position, coalesced frames, malformed data, field offsets")
    }
}
