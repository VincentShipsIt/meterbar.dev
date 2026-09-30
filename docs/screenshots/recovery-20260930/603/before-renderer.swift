
import AppKit
import SwiftUI
import MeterBarShared
@testable import MeterBar

struct FixtureStatusDots: View {
 let openDetail: () -> Void = {}
 let hoverOpenDetail: (() -> Void)? = nil
 let reduceMotion = true
 let summaryText = "All provider pages operational"
     var body: some View {
        Button(action: openDetail) {
            HStack(spacing: 5) {
                ForEach(ServiceType.allCases) { service in
                    let indicator = ProviderStatusIndicator.none
                    Circle()
                        .fill(indicator.tint)
                        .frame(width: 7, height: 7)
                        .help(service.statusPageDisplayName)
                        .animation(
                            MeterBarTheme.Motion.snappy(reduceMotion: reduceMotion),
                            value: indicator
                        )
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .help("Provider status")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Provider status")
        .accessibilityValue(summaryText)
        .accessibilityHint("Show provider status details")
        .onHover { if $0 { hoverOpenDetail?() } }
        
    }
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
   private var mainColumn: some View {
    VStack(spacing: 0) {
      popoverHeader

      Divider()

      ScrollView {
        VStack(spacing: 10) {
          fixtureCards

          Divider()
          fixtureAwakeControl

          
        }
        .padding(MeterBarTheme.Spacing.md)
        .background(
          GeometryReader { proxy in
            Color.clear.preference(
              key: MenuContentHeightPreferenceKey.self,
              value: proxy.size.height
            )
          }
        )
      }
      .scrollIndicators(.hidden)
      .scrollContentBackground(.hidden)
      .frame(height: scrollHeight)
    }
  }
   private var popoverHeader: some View {
    HStack(spacing: 8) {
      FixtureStatusDots()

      Spacer()

      // Dashboard + Refresh fused into one glass capsule (were two separate glass
      // circles) so the header actions read as a single pill, matching the
      // status-dots pill on the left.
      HStack(spacing: 2) {
        Button(action: openDashboard) {
          Image(systemName: MenuBarOverlayIcons.dashboard)
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 32, height: 30)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .help("Open Usage Dashboard")
        .accessibilityLabel("Open Dashboard")

        Button {
          
        } label: {
          RefreshingIcon(isRefreshing: false)
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 32, height: 30)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .help("Refresh usage (⌘R)")
        .accessibilityLabel("Refresh")
        .accessibilityValue("")
        .meterBarRefreshShortcut()
        .disabled(false)
      }
      .glassEffect(.regular.interactive(), in: .capsule)
    }
    .font(.body)
    .padding(.horizontal, MeterBarTheme.Spacing.lg)
    .padding(.vertical, MeterBarTheme.Spacing.sm)
  }
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

private enum MenuBarOverlayIcons {
  static let dashboard = "rectangle.split.2x1"
}
private struct MenuContentHeightPreferenceKey: PreferenceKey {
  static var defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}