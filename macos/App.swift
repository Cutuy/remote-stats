import AppKit
import SwiftUI
import Darwin

func bytes(_ value: UInt64) -> String {
    let units=["B","KiB","MiB","GiB","TiB"]
    var n=Double(value), i=0
    while n >= 1024 && i < units.count-1 { n /= 1024; i += 1 }
    return String(format: n < 10 && i > 0 ? "%.2f %@" : "%.0f %@", n, units[i])
}
func percent(_ n: Double) -> String { String(format: "%.0f%%", n) }

final class SSHStream {
    private let lock=NSLock()
    private var generation=0
    private var process: Process?
    func stop() {
        lock.lock();generation += 1;let p=process;process=nil;lock.unlock()
        if let p=p, p.isRunning { p.terminate() }
    }
    func start(host: String, port: Int, receive: @escaping (Snapshot)->Void, status: @escaping (String)->Void) {
        stop();lock.lock();let gen=generation;lock.unlock()
        func active() -> Bool { self.lock.lock();defer { self.lock.unlock() };return self.generation == gen }
        DispatchQueue.global(qos:.utility).async {
            var delay=1.0
            while active() {
                let p=Process(), output=Pipe(), input=Pipe(), errors=Pipe()
                p.executableURL=URL(fileURLWithPath:"/usr/bin/ssh")
                p.arguments=["-T","-o","BatchMode=yes","-o","ConnectTimeout=8","-o","ServerAliveInterval=5","-o","ServerAliveCountMax=3","-o","StrictHostKeyChecking=yes","-o","ExitOnForwardFailure=yes","-o","ControlMaster=no","-o","ControlPath=none","-W","127.0.0.1:\(port)",host]
                p.standardOutput=output;p.standardInput=input;p.standardError=errors
                do {
                    self.lock.lock()
                    guard self.generation == gen else { self.lock.unlock();return }
                    do { try p.run();self.process=p;self.lock.unlock() }
                    catch { self.lock.unlock();throw error }
                    if active() { status("Connecting…") }
                    var decoder=FrameDecoder()
                    do {
                        var storage=[UInt8](repeating:0,count:4096)
                        while active() {
                            let count=Darwin.read(output.fileHandleForReading.fileDescriptor,&storage,storage.count)
                            if count == 0 { break }
                            if count < 0 { if errno == EINTR { continue };throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
                            for frame in try decoder.append(Data(storage.prefix(count))) {
                                if active() { receive(frame);delay=1 }
                            }
                        }
                    } catch {
                        if p.isRunning { p.terminate() }
                        throw error
                    }
                    if p.isRunning { p.terminate() }
                    p.waitUntilExit()
                    let diagnostic=String(decoding:errors.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
                    if active() { status(diagnostic.isEmpty ? "Disconnected · retrying…" : diagnostic) }
                } catch {
                    if active() { status("Connection failed: \(error.localizedDescription)") }
                }
                self.lock.lock();if self.generation == gen { self.process=nil };self.lock.unlock()
                // Short cancellable waits make Quit and host changes immediate.
                var waited=0.0
                while active() && waited < delay { Thread.sleep(forTimeInterval:0.2);waited += 0.2 }
                delay=min(30,delay*2)
            }
        }
    }
    deinit { stop() }
}

final class Model: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var cpuHistory: [Double]=[]
    @Published var ramHistory: [Double]=[]
    @Published var state="Connecting…"
    @Published var connected=false
    @Published var selected="CPU" {
        didSet { if oldValue != selected { selectionChanged?() } }
    }
    @Published var panelHeight: CGFloat=790
    var selectionChanged: (() -> Void)?
    @Published var host=UserDefaults.standard.string(forKey:"host") ?? ""
    @Published var port=UserDefaults.standard.integer(forKey:"port") == 0 ? 47391 : UserDefaults.standard.integer(forKey:"port")
    @Published var settings=false
    private var lastReceived=Date.distantPast
    private var timer: Timer?
    private let stream=SSHStream()
    private var epoch=0
    var changed: (() -> Void)?
    func connect() {
        epoch += 1;let currentEpoch=epoch
        snapshot=nil;cpuHistory=[];ramHistory=[];connected=false;state="Connecting…";changed?()
        guard !host.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {
            stream.stop();state="Choose an SSH host in settings";changed?();return
        }
        stream.start(host:host,port:port,receive:{ [weak self] frame in
            DispatchQueue.main.async {
                guard let self=self,self.epoch == currentEpoch else { return }
                if let old=self.snapshot,frame.sequence <= old.sequence { self.cpuHistory=[];self.ramHistory=[] }
                self.snapshot=frame;self.lastReceived=Date();self.connected=true
                self.state=frame.ready ? "Live · every \(Int(frame.interval))s" : "Warming up…"
                if frame.ready {
                    self.cpuHistory.append(frame.cpu);self.ramHistory.append(frame.memoryPercent)
                    if self.cpuHistory.count > 90 { self.cpuHistory.removeFirst() }
                    if self.ramHistory.count > 90 { self.ramHistory.removeFirst() }
                }
                self.changed?()
            }
        },status:{ [weak self] message in
            DispatchQueue.main.async {
                guard let self=self,self.epoch == currentEpoch else { return }
                self.connected=false;self.state=message;self.changed?()
            }
        })
        if timer == nil {
            timer=Timer.scheduledTimer(withTimeInterval:2,repeats:true) { [weak self] _ in
                guard let self=self,self.connected,let s=self.snapshot else { return }
                if Date().timeIntervalSince(self.lastReceived) > max(10,s.interval*3) {
                    self.connected=false;self.state="No recent data · reconnecting…";self.changed?()
                    self.reconnectAfterStall()
                }
            }
            timer?.tolerance=0.5
        }
    }
    private func reconnectAfterStall() {
        // Reconnect without retaining stale values in the menu bar.
        connect()
    }
    func save(host: String, port: String) -> Bool {
        let value=host.trimmingCharacters(in:.whitespacesAndNewlines)
        guard value.range(of:"^[A-Za-z0-9_][A-Za-z0-9_.@-]*$",options:.regularExpression) != nil,
              let p=Int(port), (1...65535).contains(p) else { return false }
        self.host=value;self.port=p;UserDefaults.standard.set(value,forKey:"host");UserDefaults.standard.set(p,forKey:"port")
        settings=false;connect();return true
    }
    func stop() { epoch += 1;timer?.invalidate();stream.stop() }
}

struct Ring: View {
    var value: Double
    var color: Color
    var title: String
    var caption: String
    var diameter: CGFloat=92
    var body: some View {
        VStack(spacing:7) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.10),lineWidth:9)
                Circle().trim(from:0,to:min(1,max(0,value/100))).stroke(color,style:StrokeStyle(lineWidth:9,lineCap:.round)).rotationEffect(.degrees(-90))
                Text(title).font(.system(size:23,weight:.medium,design:.rounded)).monospacedDigit()
            }.frame(width:diameter,height:diameter)
            Text(caption).font(.system(size:10,weight:.semibold)).foregroundStyle(.secondary)
        }
    }
}
struct History: View {
    var values: [Double]
    var color: Color
    var body: some View {
        Canvas { ctx,size in
            guard !values.isEmpty else { return }
            let visible=Array(values.suffix(90)),step=size.width/89
            let start=size.width-CGFloat(visible.count-1)*step
            var line=Path()
            for (i,v) in visible.enumerated() {
                let point=CGPoint(x:start+CGFloat(i)*step,y:size.height-4-CGFloat(min(100,max(0,v)))/100*(size.height-8))
                if i == 0 { line.move(to:point) } else { line.addLine(to:point) }
            }
            var fill=line;fill.addLine(to:CGPoint(x:size.width,y:size.height));fill.addLine(to:CGPoint(x:start,y:size.height));fill.closeSubpath()
            ctx.fill(fill,with:.linearGradient(Gradient(colors:[color.opacity(0.7),color.opacity(0.12)]),startPoint:.zero,endPoint:CGPoint(x:0,y:size.height)))
            ctx.stroke(line,with:.color(color),lineWidth:1.5)
        }.frame(height:80).background(Color.primary.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius:7))
    }
}
struct CoreBars: View {
    let snapshot: Snapshot
    var body: some View {
        HStack(alignment:.bottom,spacing:3) {
            ForEach(snapshot.coreKinds.indices.filter { snapshot.coreKinds[$0] != .offline },id:\.self) { i in
                let kind=snapshot.coreKinds[i]
                let color: Color=kind == .performance ? .purple : kind == .efficiency ? .teal : .gray
                GeometryReader { g in
                    VStack { Spacer(minLength:0);RoundedRectangle(cornerRadius:2).fill(color.gradient).frame(height:max(2,g.size.height*snapshot.coreUsage[i]/100)) }
                }.help("\(kind == .performance ? "P-core thread" : kind == .efficiency ? "E-core" : "Logical CPU") \(i): \(percent(snapshot.coreUsage[i]))")
            }
        }.frame(height:30).padding(5).background(Color.primary.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius:6))
    }
}
struct SectionLabel: View {
    let text: String
    var body: some View {
        HStack(spacing:12) { Rectangle().frame(height:1);Text(text).font(.system(size:10,weight:.semibold)).tracking(1.5).fixedSize();Rectangle().frame(height:1) }.foregroundStyle(.secondary.opacity(0.6)).padding(.top,5)
    }
}
struct Detail: View {
    var label: String
    var value: String
    var color: Color?=nil
    var body: some View {
        HStack {
            if let color=color { RoundedRectangle(cornerRadius:3).fill(color).frame(width:9,height:9) }
            Text(label).foregroundStyle(.secondary);Spacer();Text(value).monospacedDigit()
        }.font(.system(size:12))
    }
}
struct ProcessList: View {
    let processes: [RemoteProcess]
    let cpu: Bool
    var body: some View {
        VStack(spacing:8) {
            HStack { Text("PROCESS / PID");Spacer();Text(cpu ? "CPU" : "RESIDENT RAM") }.font(.system(size:9,weight:.semibold)).foregroundStyle(.tertiary)
            ForEach(processes) { p in
                HStack(spacing:7) {
                    Image(systemName:"terminal").foregroundStyle(.secondary).font(.system(size:11))
                    Text(p.name).lineLimit(1).truncationMode(.middle)
                    Text(String(p.pid)).font(.system(size:9,design:.monospaced)).foregroundStyle(.tertiary)
                    Spacer(minLength:4)
                    Text(cpu ? String(format:"%.1f%%",p.cpu) : bytes(p.rss)).monospacedDigit()
                }.font(.system(size:12)).help("PID \(p.pid) · \(p.name) · \(bytes(p.rss)) RSS · \(String(format:"%.1f",p.cpu))% CPU")
            }
            if cpu { Text("Process CPU: 100% = one logical CPU").font(.system(size:9)).foregroundStyle(.tertiary).frame(maxWidth:.infinity,alignment:.leading) }
        }
    }
}
struct SettingsView: View {
    @ObservedObject var model: Model
    @State private var host=""
    @State private var port=""
    @State private var invalid=false
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("Remote connection").font(.headline)
            Text("Uses your existing SSH keys and config. The collector listens only on the Linux host’s loopback interface.").font(.caption).foregroundStyle(.secondary)
            TextField("user@host or SSH alias",text:$host)
            TextField("Collector port",text:$port)
            if invalid { Text("Enter an SSH host and port from 1 to 65535.").font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { model.settings=false };Spacer()
                Button("Save & reconnect") { invalid = !model.save(host:host,port:port) }.keyboardShortcut(.defaultAction)
            }
            Divider()
            Text("Sampling: 2 seconds by default. Change the Linux service’s --interval-ms option to adjust it. History stays on this Mac for the last 90 samples.").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width:330).onAppear { host=model.host;port=String(model.port) }
    }
}
struct Panel: View {
    @ObservedObject var model: Model
    var body: some View {
        // Normally the viewport fits all content. On short displays, retain
        // trackpad/wheel access without a permanent scrollbar beside the panel.
        ScrollView(.vertical,showsIndicators:false) {
            PanelContent(model:model)
        }.frame(width:352,height:model.panelHeight)
         .sheet(isPresented:$model.settings) { SettingsView(model:model) }
    }
}
struct PanelContent: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(spacing:11) {
            HStack {
                Image(systemName:"server.rack").foregroundStyle(.secondary)
                Spacer();Text("Remote \(model.selected)").font(.system(size:17,weight:.semibold));Spacer()
                Button { model.settings=true } label: { Image(systemName:"gearshape") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Connection settings")
            }
            HStack(spacing:5) {
                Circle().fill(model.connected ? Color.green : Color.orange).frame(width:5,height:5)
                Text(model.snapshot?.hostname ?? model.host).lineLimit(1)
                Spacer();Text(model.connected ? model.state : "Offline").foregroundStyle(.secondary)
            }.font(.system(size:10)).foregroundStyle(.secondary)
            Picker("Metric",selection:$model.selected) { Text("CPU").tag("CPU");Text("RAM").tag("RAM") }.pickerStyle(.segmented).labelsHidden()
            if !model.connected {
                VStack(alignment:.leading,spacing:7) {
                    Text("Waiting for \(model.host)").font(.system(size:12,weight:.medium))
                    Text(model.state).font(.system(size:10)).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Reconnect now") { model.connect() }.font(.caption)
                }.frame(maxWidth:.infinity,alignment:.leading).padding(12).background(Color.orange.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius:8))
            }
            if let s=model.snapshot {
                if !model.connected { Text("Last received \(s.timestamp.formatted(date:.omitted,time:.standard)) · values below are stale").font(.caption2).foregroundStyle(.orange) }
                if model.selected == "CPU" { cpu(s) } else { ram(s) }
            } else {
                Image(systemName:"network").font(.system(size:36)).foregroundStyle(.secondary).padding(.vertical,25)
                Text("Waiting for the first sample").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Text(model.snapshot.map { "\($0.collectMicros) µs/sample · 1 KiB/frame" } ?? "Encrypted over SSH").font(.system(size:9)).foregroundStyle(.tertiary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).font(.system(size:10)).foregroundStyle(.secondary)
            }
        }.padding(17).frame(width:352).fixedSize(horizontal:false,vertical:true)
    }
    @ViewBuilder func cpu(_ s: Snapshot) -> some View {
        HStack(spacing:37) {
            Ring(value:s.cpu,color:.blue,title:s.ready ? percent(s.cpu) : "—",caption:"TOTAL CPU")
            Ring(value:min(100,s.load[0]/Double(s.cores)*100),color:.teal,title:String(format:"%.2f",s.load[0]),caption:"1-MIN LOAD")
        }.padding(.vertical,5)
        SectionLabel(text:"USAGE HISTORY")
        History(values:model.cpuHistory,color:.blue)
        CoreBars(snapshot:s)
        SectionLabel(text:"DETAILS")
        VStack(spacing:7) {
            if s.hasHybridCores {
                Detail(label:"Performance cores",value:percent(s.usage(for:.performance)),color:.purple)
                Detail(label:"Efficiency cores",value:percent(s.usage(for:.efficiency)),color:.teal)
                Detail(label:"Core layout",value:"\(s.performanceCores)P + \(s.efficiencyCores)E · \(s.cores) threads")
            }
            Detail(label:"User",value:percent(s.user),color:.blue)
            Detail(label:"System",value:percent(s.system),color:.red)
            Detail(label:"Idle + I/O wait",value:percent(max(0,100-s.cpu)),color:.gray)
            Detail(label:"Logical CPUs / processes",value:"\(s.cores) / \(s.processCount)")
            Detail(label:"Uptime",value:"\(s.uptime/86400)d \(s.uptime%86400/3600)h \(s.uptime%3600/60)m")
            Detail(label:"Load · 1 / 5 / 15 min",value:s.load.map { String(format:"%.2f",$0) }.joined(separator:" / "))
        }
        SectionLabel(text:"TOP PROCESSES")
        ProcessList(processes:s.topCPU,cpu:true)
        SectionLabel(text:"NETWORK & DISK")
        VStack(spacing:6) {
            Detail(label:"Network · ↓ / ↑",value:"\(bytes(s.rx))/s / \(bytes(s.tx))/s")
            Detail(label:"Disk · read / write",value:"\(bytes(s.diskRead))/s / \(bytes(s.diskWrite))/s")
        }
    }
    @ViewBuilder func ram(_ s: Snapshot) -> some View {
        HStack(spacing:37) {
            Ring(value:s.memoryPercent,color:.blue,title:percent(s.memoryPercent),caption:"USED MEMORY")
            Ring(value:s.swapTotal > 0 ? Double(s.swapTotal-s.swapFree)/Double(s.swapTotal)*100 : 0,color:.orange,title:s.swapTotal > 0 ? percent(Double(s.swapTotal-s.swapFree)/Double(s.swapTotal)*100) : "—",caption:"SWAP USED")
        }.padding(.vertical,5)
        SectionLabel(text:"USAGE HISTORY")
        History(values:model.ramHistory,color:.blue)
        SectionLabel(text:"DETAILS")
        VStack(spacing:8) {
            Detail(label:"Used",value:bytes(s.memoryUsed),color:.blue)
            ProgressView(value:s.memoryPercent,total:100).tint(.blue)
            Detail(label:"Available",value:bytes(s.memoryAvailable),color:.green)
            Detail(label:"Total",value:bytes(s.memoryTotal))
            Detail(label:"Free",value:bytes(s.memoryFree),color:.gray)
            Detail(label:"Page cache",value:bytes(s.cached),color:.teal)
            Detail(label:"Buffers",value:bytes(s.buffers),color:.purple)
            Detail(label:"Swap used / total",value:"\(bytes(s.swapTotal-s.swapFree)) / \(bytes(s.swapTotal))",color:.orange)
            Text("Used = total − available. Available includes reclaimable cache. Process RAM is RSS; shared pages may be counted in multiple processes.").font(.system(size:9)).foregroundStyle(.tertiary).fixedSize(horizontal:false,vertical:true)
        }
        SectionLabel(text:"TOP PROCESSES")
        ProcessList(processes:s.topMemory,cpu:false)
        SectionLabel(text:"ROOT FILESYSTEM")
        Detail(label:"Available / total",value:"\(bytes(s.fsAvailable)) / \(bytes(s.fsTotal))")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model=Model()
    private var cpuItem: NSStatusItem!, ramItem: NSStatusItem!
    private let popover=NSPopover()
    private var anchorItem: NSStatusItem?
    private var sizingView: NSHostingView<PanelContent>?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        cpuItem=NSStatusBar.system.statusItem(withLength:46)
        ramItem=NSStatusBar.system.statusItem(withLength:46)
        for item in [cpuItem!,ramItem!] {
            item.button?.target=self;item.button?.action=#selector(toggle(_:))
            item.button?.imagePosition = .imageOnly
            item.button?.imageScaling = .scaleNone
        }
        popover.behavior = .transient
        sizingView=NSHostingView(rootView:PanelContent(model:model))
        let hosting=NSHostingController(rootView:Panel(model:model))
        // AppKit must know the final size before choosing the screen position.
        // Otherwise NSHostingController can grow the default 320pt popover upward.
        hosting.sizingOptions=[]
        popover.contentViewController=hosting
        popover.animates=false
        model.selectionChanged={ [weak self] in
            DispatchQueue.main.async { self?.sizePanel() }
        }
        model.changed={ [weak self] in self?.update() }
        update();model.connect()
        if model.host.isEmpty {
            DispatchQueue.main.async { self.show(self.cpuItem,"CPU");self.model.settings=true }
        } else if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline:.now()+2) { self.show(self.cpuItem,"CPU") }
        }
    }
    func update() {
        let live=model.connected && model.snapshot?.ready == true
        set(cpuItem,label:"R·CPU",value:live ? percent(model.snapshot!.cpu) : "—")
        set(ramItem,label:"R·RAM",value:live ? percent(model.snapshot!.memoryPercent) : "—")
        let tip="Remote Stats · \(model.host)\n\(model.state)"
        cpuItem.button?.toolTip=tip;ramItem.button?.toolTip=tip
        cpuItem.button?.setAccessibilityLabel("Remote CPU")
        ramItem.button?.setAccessibilityLabel("Remote RAM")
        if popover.isShown {
            DispatchQueue.main.async { [weak self] in self?.sizePanel() }
        }
    }
    func set(_ item: NSStatusItem,label: String,value: String) {
        // A multiline NSButton title uses the entire 26pt menu bar height and
        // its baseline changes with the value. A template image keeps both rows
        // centered, bounded, and correct for the menu bar's light/dark appearance.
        let image=NSImage(size:NSSize(width:42,height:22),flipped:false) { rect in
            let paragraph=NSMutableParagraphStyle();paragraph.alignment = .center
            let small:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:8,weight:.medium),.foregroundColor:NSColor.black,.paragraphStyle:paragraph]
            let big:[NSAttributedString.Key:Any]=[.font:NSFont.monospacedDigitSystemFont(ofSize:12,weight:.medium),.foregroundColor:NSColor.black,.paragraphStyle:paragraph]
            (label as NSString).draw(in:NSRect(x:0,y:13,width:rect.width,height:9),withAttributes:small)
            (value as NSString).draw(in:NSRect(x:0,y:0,width:rect.width,height:15),withAttributes:big)
            return true
        }
        image.isTemplate=true
        item.button?.title=""
        item.button?.image=image
        item.button?.setAccessibilityValue(value)
    }
    private func sizePanel() {
        let screen=anchorItem?.button?.window?.screen ?? NSScreen.main
        let available=max(200,(screen?.visibleFrame.height ?? 900)-30)
        guard let sizingView=sizingView else { return }
        sizingView.layoutSubtreeIfNeeded()
        let contentHeight=ceil(sizingView.fittingSize.height)
        let size=NSSize(width:352,height:min(max(1,contentHeight),available))
        if abs(model.panelHeight-size.height)>0.5 { model.panelHeight=size.height }
        popover.contentViewController?.preferredContentSize=size
        popover.contentSize=size
    }

    @objc func toggle(_ sender: NSStatusBarButton) {
        let item=sender === cpuItem.button ? cpuItem! : ramItem!
        let metric=sender === cpuItem.button ? "CPU" : "RAM"
        if popover.isShown && model.selected == metric { popover.performClose(nil) }
        else { show(item,metric) }
    }
    func show(_ item: NSStatusItem,_ metric: String) {
        if popover.isShown { popover.performClose(nil) }
        anchorItem=item
        model.selected=metric
        sizePanel()
        if let button=item.button {
            NSApp.activate(ignoringOtherApps:true)
            popover.show(relativeTo:button.bounds,of:button,preferredEdge:.minY)
            popover.contentViewController?.view.window?.makeKey()

        }
    }
    func applicationWillTerminate(_ notification: Notification) { model.stop() }
}
@main
enum RemoteStatsApp {
    static func main() {
        let app=NSApplication.shared
        let delegate=AppDelegate()
        app.delegate=delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
