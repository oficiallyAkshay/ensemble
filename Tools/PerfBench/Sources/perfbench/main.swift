import AppKit
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
setvbuf(stdout, nil, _IOLBF, 0)
guard let mode = args.first else { print("usage: perfbench native | formats | pointer [noise=0.004] [sweep] | web [transfer=pull|b64|bgra] [w=320] [h=240] [q=0.6] [hz=30] [sec=15] [delegate=GPU|CPU] [model=landmarker|detector] [face=1|0] [max-cpu-ms=N] [max-growth-mb=N]"); exit(2) }
switch mode {
case "native": runNative()
case "formats": runFormats()
case "pointer": runPointer(Array(args.dropFirst()))
case "web":
    var cfg = WebConfig()
    for a in args.dropFirst() {
        let kv = a.split(separator: "=", maxSplits: 1).map(String.init)
        guard kv.count == 2 else { continue }
        switch kv[0] {
        case "transfer": cfg.transfer = kv[1]
        case "w": cfg.w = Int(kv[1])!
        case "h": cfg.h = Int(kv[1])!
        case "q": cfg.quality = Double(kv[1])!
        case "hz": cfg.hz = Double(kv[1])!
        case "sec": cfg.seconds = Double(kv[1])!
        case "delegate": cfg.delegate = kv[1]
        case "model": cfg.model = kv[1]
        case "face": cfg.face = kv[1] == "1"
        case "max-cpu-ms": cfg.maxCPUms = Double(kv[1])
        case "max-growth-mb": cfg.maxGrowthMB = Double(kv[1])
        default: break
        }
    }
    MainActor.assumeIsolated { runWeb(cfg) }
default: print("unknown mode"); exit(2)
}
