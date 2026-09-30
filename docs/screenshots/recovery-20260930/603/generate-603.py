from pathlib import Path
import subprocess
import sys
base=Path(sys.argv[1])
pr=Path(sys.argv[2])

def balanced(s,start,left,right):
    pos=s.index(left,start);depth=0
    for i in range(pos,len(s)):
        if s[i]==left:depth+=1
        elif s[i]==right:
            depth-=1
            if depth==0:return i+1
    raise ValueError('unbalanced')

def member(s,name):
    start=s.index('  private var '+name+': some View')
    return s[start:balanced(s,start,'{','}')]

common=r'''
import AppKit
import SwiftUI
import MeterBarShared
@testable import MeterBar

struct FixtureStatusDots: View {
 let openDetail: () -> Void = {}
 let hoverOpenDetail: (() -> Void)? = nil
 let reduceMotion = true
 let summaryText = "All provider pages operational"
 STATUS_BODY
}

struct FixturePopover: View {
 let scrollHeight: CGFloat = 550
 let snapshots: [ProviderSnapshot]
 let openDashboard: () -> Void = {}
 let openStatusDetail: () -> Void = {}
 let hoverOpenStatusDetail: () -> Void = {}
 var body: some View {
   mainColumn
     .frame(width: MenuBarPopoverGeometry.width, height: scrollHeight + MenuBarPopoverGeometry.chromeHeight)
     .background(MeterBarTheme.Surface.chrome(radius: MeterBarTheme.companionShellRadius))
     .clipShape(RoundedRectangle(cornerRadius: MeterBarTheme.companionShellRadius, style: .continuous))
 }
 var fixtureCards: some View {
   VStack(spacing: 8) {
     ForEach(snapshots) { snapshot in
       DashboardTile(padding: .popover) {
         VStack(alignment: .leading, spacing: 10) {
           ProviderCardHeader(snapshot: snapshot, showsDisclosureChevron: true)
           VStack(alignment: .leading, spacing: 9) {
             ForEach(snapshot.limits) { limit in
               LimitRow(limit: limit, accentColor: snapshot.accentColor, density: .compact)
             }
           }
         }
       }
     }
   }
 }
 var fixtureAwakeControl: some View {
   Toggle(isOn: .constant(false)) { Label("Stay awake", systemImage:"flame") }
     .meterBarSwitch()
 }
 MAIN_COLUMN
 POPOVER_HEADER
}

struct FixtureSettings: View {
 var body: some View {
   VStack(alignment: .leading, spacing: 14) {
     SettingsPanelSection(title:"Refresh",systemImage:"arrow.clockwise",color:MeterBarTheme.appAccent) {
       SettingsRowView(title:"Auto-refresh interval",detail:"Choose how often MeterBar updates usage.") {
         Picker("Interval",selection:.constant(10)) {
           Text("10 minutes").tag(10); Text("30 minutes").tag(30)
         }.labelsHidden().pickerStyle(.menu).fixedSize()
       }
       SettingsRowView(title:"Manual refresh") {
         Button {} label: { Image(systemName:"arrow.clockwise") }.buttonStyle(.glass)
       }
     }
     SettingsPanelSection(title:"Menu Bar & Popover",systemImage:"menubar.rectangle",color:MeterBarTheme.appAccent) {
       SettingsRowView(title:"Follow focused app",detail:"Show the provider used by the focused app.") {
         Toggle("Follow focused app",isOn:.constant(true)).labelsHidden().meterBarSwitch()
       }
       SettingsRowView(title:"Reset countdown",detail:"Choose how reset times appear.") {
         Picker("Reset format",selection:.constant("Countdown")) {
           Text("Countdown").tag("Countdown"); Text("Clock time").tag("Clock time")
         }.labelsHidden().pickerStyle(.segmented).fixedSize()
       }
     }
   }.padding(22).frame(width:680).background(MeterBarDetailBackground())
 }
}

struct FixtureIcon: View {
 var body: some View {
   HStack(spacing:8) {
     Image(nsImage:MenuBarIconRenderer.meterIcon()).frame(width:18,height:18)
     Text("75%").font(.system(size:13)).monospacedDigit()
     Divider().frame(height:18)
     Image(nsImage:MenuBarIconRenderer.stayAwakeIndicator(baseImage:MenuBarIconRenderer.meterIcon()))
       .frame(width:31,height:18)
     Text("75%").font(.system(size:13)).monospacedDigit()
   }.padding(12).background(.regularMaterial)
 }
}

@main struct Render {
 @MainActor static func main() throws {
   NSApplication.shared.setActivationPolicy(.prohibited)
   let args = CommandLine.arguments
   let output=URL(fileURLWithPath:args[1],isDirectory:true)
   let stage=args[2]
   try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
   let providers:[ServiceType]=[.claudeCode,.codexCli,.grok,.cursor,.openRouter]
   let snapshots = providers.enumerated().map { i,provider in
     ProviderSnapshot(id: "fixture-\(i)",title:provider.displayName,service:provider,updatedAt:nil,
       limits:[SnapshotLimit(id:"session",kind:.session,title:"Session",usageLimit:UsageLimit(used:Double(20+i*15),total:100,resetTime:nil)),
               SnapshotLimit(id:"weekly",kind:.weekly,title:"Weekly",usageLimit:UsageLimit(used:Double(10+i*12),total:100,resetTime:nil))],
       emptyDetail:"Synthetic fixture",extraUsage:nil,resetCreditsAvailable:nil,accountID:nil)
   }
   for dark in [false,true] {
     let mode=dark ? "dark":"light"
     try render(FixturePopover(snapshots:snapshots),name:"\(stage)-popover-\(mode)",dark:dark,output:output)
     try render(DashboardOverviewSection(snapshots:snapshots,tightestLimit:snapshots.first?.limits.first,costSummary:nil,onSelectProvider:{ _ in }).frame(width:1000),name:"\(stage)-dashboard-overview-\(mode)",dark:dark,output:output)
     try render(FixtureSettings(),name:"\(stage)-settings-components-\(mode)",dark:dark,output:output)
     try render(FixtureIcon(),name:"\(stage)-icon-template-\(mode)",dark:dark,output:output)
   }
 }
 @MainActor static func render<V:View>(_ view:V,name:String,dark:Bool,output:URL) throws {
   let scheme:ColorScheme=dark ? .dark:.light
   let appearance=NSAppearance(named:dark ? .darkAqua:.aqua)
   NSApplication.shared.appearance = appearance
   let host=NSHostingView(rootView:view.padding(20).background(Color(nsColor:dark ? NSColor(calibratedWhite:0.11,alpha:1):NSColor(calibratedWhite:0.93,alpha:1))).environment(\.colorScheme,scheme))
   host.appearance=appearance
   host.frame=NSRect(origin:.zero,size:host.fittingSize)
   let window=NSWindow(contentRect:host.frame,styleMask:[.borderless],backing:.buffered,defer:false)
   window.isReleasedWhenClosed=false;window.appearance=appearance;window.contentView=host
   for _ in 0..<4 {
     host.layoutSubtreeIfNeeded()
     RunLoop.current.run(until:Date(timeIntervalSinceNow:0.025))
   }
   host.displayIfNeeded()
   guard let rep=host.bitmapImageRepForCachingDisplay(in:host.bounds) else { throw NSError(domain:"render",code:1) }
   host.cacheDisplay(in:host.bounds,to:rep)
   guard let png=rep.representation(using:.png,properties:[:]) else { throw NSError(domain:"render",code:2) }
   try png.write(to:output.appendingPathComponent(name+".png"))
   print(name,host.frame.size)
 }
}
'''

for stage,root in [('before',base),('after',pr)]:
    source=(root/'MeterBar/Views/MenuBarView.swift').read_text()
    main=member(source,'mainColumn')
    start=main.index('PopoverOverviewPanel(')
    end=balanced(main,start,'(',')')
    main=main[:start]+'fixtureCards'+main[end:]
    start=main.index('if SessionWakeMenuControl.shouldShow(')
    end=balanced(main,start,'{','}')
    main=main[:start]+main[end:]
    main=main.replace('StayAwakeMenuControl()','fixtureAwakeControl')
    header=member(source,'popoverHeader')
    start=header.index('PopoverHeaderStatusDots(')
    end=balanced(header,start,'(',')')
    header=header[:start]+'FixtureStatusDots()'+header[end:]
    header=header.replace('Task { await dataManager.refreshForExplicitAction(.manualRefresh) }','')
    header=header.replace('dataManager.isLoading ? "Refreshing usage" : "Refresh usage (⌘R)"','"Refresh usage (⌘R)"')
    header=header.replace('dataManager.isLoading ? "Refreshing" : ""','""')
    header=header.replace('dataManager.isLoading','false')
    dots=(root/'MeterBar/Views/MenuBarHeaderStatusDots.swift').read_text()
    start=dots.index('    var body: some View',dots.index('struct PopoverHeaderStatusDots'))
    body=dots[start:balanced(dots,start,'{','}')]
    body=body.replace('statusMonitor.reports[service]?.summary.indicator ?? .unknown','ProviderStatusIndicator.none')
    body=body.replace('.task { await statusMonitor.refreshAllIfNeeded() }','')
    rendered=common.replace('STATUS_BODY',body).replace('MAIN_COLUMN',main).replace('POPOVER_HEADER',header)
    for declaration in ['private enum MenuBarOverlayIcons', 'private struct MenuContentHeightPreferenceKey']:
        start=source.index(declaration)
        rendered += '\n'+source[start:balanced(source,start,'{','}')]
    Path('/private/tmp/meterbar-review-603-'+stage+'-renderer.swift').write_text(rendered)
