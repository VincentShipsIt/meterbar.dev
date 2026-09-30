import AppKit
import SwiftUI
import MeterBarShared
@testable import MeterBar
@main struct AuditLayout {
 @MainActor static func main() throws {
 UserDefaults.standard.set(7,forKey:StorageKeys.costsWindowDays)
 for width in [CGFloat(834),CGFloat(1000)] {
 let host = NSHostingView(rootView:DashboardUsageSection(summary:DemoData.costSummary()).frame(width:width).fixedSize(horizontal:false,vertical:true).padding(20).background(Color(nsColor:NSColor(calibratedWhite:0.11,alpha:1))).environment(\.colorScheme,.dark))
 host.appearance = NSAppearance(named:.darkAqua)
 host.frame = NSRect(origin:.zero,size:host.fittingSize)
 let window = NSWindow(contentRect:host.frame,styleMask:[.borderless],backing:.buffered,defer:false)
 window.isReleasedWhenClosed = false; window.appearance = host.appearance; window.contentView = host
 host.layoutSubtreeIfNeeded()
 let rep = host.bitmapImageRepForCachingDisplay(in:host.bounds)!
 host.cacheDisplay(in:host.bounds,to:rep)
 try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"/private/tmp/meterbar-review-601-repaired-snapshots/boundary-\(Int(width)).png"))
 print("Offscreen width",width,"host",host.frame.size)
 }
 }
}
