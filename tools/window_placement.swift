// Prints where a process's windows are, without asking the window manager:
//
//   swift tools/window_placement.swift PID
//
// One line per normal-level window: its frame (global points, top-left origin), whether macOS
// orders it on screen and, if so, how much of it lies on a connected display. Tiling window
// managers that hide workspaces by parking windows off screen (OmniWM, AeroSpace) leave hidden
// windows on screen but about 0% visible; minimized windows and hidden apps report onscreen=0.
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2, let pid = Int(CommandLine.arguments[1]) else {
    FileHandle.standardError.write("usage: window_placement.swift PID\n".data(using: .utf8)!)
    exit(2)
}

var count: UInt32 = 0
CGGetActiveDisplayList(0, nil, &count)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
CGGetActiveDisplayList(count, &ids, &count)
let displays = ids.map { CGDisplayBounds($0) }

let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
var found = false
for w in windows {
    guard (w[kCGWindowOwnerPID as String] as? Int) == pid,
          (w[kCGWindowLayer as String] as? Int) == 0,
          let bounds = w[kCGWindowBounds as String],
          let frame = CGRect(dictionaryRepresentation: bounds as! CFDictionary),
          frame.width >= 100, frame.height >= 100
    else { continue }
    found = true
    let onscreen = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
    var line = "window \(w[kCGWindowNumber as String] ?? 0) onscreen=\(onscreen ? 1 : 0) "
        + "frame=\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
    if onscreen {
        let shown = displays.reduce(0.0) { sum, display in
            let part = display.intersection(frame)
            return sum + (part.isNull ? 0 : part.width * part.height)
        }
        line += " visible=\(Int((100 * shown / (frame.width * frame.height)).rounded()))%"
    }
    print(line)
}
if !found { print("no windows") }
