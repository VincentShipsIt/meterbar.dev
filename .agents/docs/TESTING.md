# Testing Guide

This guide explains how to test the MeterBar app.

## Running the App in Xcode

1. **Build and Run**:
   - Select the `MeterBar` scheme in Xcode
   - Press `Cmd+R` or click the Run button
   - The app will build and launch

2. **What to Expect**:
   - **No window will appear** - this is a menu bar app
   - Look for a **chart icon** (📊) in your menu bar (top-right area)
   - The icon should appear near the clock/date

## Testing the Menu Bar Interface

### 1. Menu Bar Icon
- ✅ Verify the chart icon appears in the menu bar
- ✅ Icon should be clickable

### 2. Menu Bar Popover
- Click the menu bar icon
- A popover should appear showing:
  - Header with "MeterBar" and refresh button
  - Service cards (if authenticated) or "No services connected" message
  - Settings and Quit buttons at the bottom

### 3. Refresh Functionality
- Click the refresh button (↻) in the popover header
- Check Xcode console for any errors
- Data should refresh (if authenticated)

## Testing Settings

### Opening Settings
1. Click the menu bar icon
2. Click the "Settings" button in the popover
3. A Settings window should open

### Settings Features to Test
- **Claude Section**:
  - Enter a session key (or test with invalid key)
  - Click "Save" - should show connection status
  - Click "Remove" - should disconnect
  - Click "How to get session key" - help sheet should appear

- **Codex Section**:
  - Enter cookies
  - Test save/remove functionality
  - Test help button

- **Cursor Section**:
  - Enter API key
  - Test save/remove functionality
  - Test help button

- **Refresh All Data**:
  - Click the button
  - Check console for API calls
  - Verify loading state

## Testing Without Real Credentials

Since you may not have real API keys, test the following:

### 1. Error Handling
- Enter invalid credentials
- Verify the app handles errors gracefully
- Check that error messages appear appropriately

### 2. Empty State
- With no services connected, the popover should show:
  - "No services connected" message
  - Instructions to open Settings

### 3. Console Logging
- Open Xcode console (`Cmd+Shift+Y`)
- Watch for:
  - Authentication attempts
  - API call errors
  - Data refresh logs

## Testing with Real Credentials

If you have access to real credentials:

### 1. Claude
1. Get session key from claude.ai (see SETUP.md)
2. Enter in Settings
3. Verify connection status turns green
4. Check menu bar popover shows Claude metrics
5. Verify refresh works

### 2. Codex
1. Get cookies from Codex dashboard
2. Enter in Settings
3. Verify connection and data display

### 3. Cursor
1. Get API key from Cursor settings
2. Enter in Settings
3. Verify connection and data display

## Testing Notifications

1. **Permission Request**:
   - On first launch, app should request notification permission
   - Check System Preferences > Notifications for the app

2. **Usage Monitoring**:
   - The app checks usage every 5 minutes
   - If usage exceeds 90%, a notification should appear
   - Check Notification Center for alerts

## Debugging Tips

### View Console Output
- In Xcode: `View > Debug Area > Activate Console` (or `Cmd+Shift+Y`)
- Look for:
  - "Failed to fetch [Service] metrics: [error]"
  - "Notification permission error: [error]"
  - Any other error messages

### Check App Status
- Open Activity Monitor
- Search for "MeterBar"
- Verify the app is running

### Menu Bar Not Showing?
- Check Console for errors
- Verify `LSUIElement` is set in Info.plist
- Try quitting and relaunching

### Data Not Refreshing?
- Check authentication status in Settings
- Verify credentials are saved (check Keychain Access app)
- Check console for API errors
- Verify network connectivity

## Testing Checklist

- [ ] App launches without crashing
- [ ] Menu bar icon appears
- [ ] Menu bar icon is clickable
- [ ] Popover appears when clicked
- [ ] Settings button opens Settings window
- [ ] Quit button terminates the app
- [ ] Refresh button works
- [ ] Settings can save/remove credentials
- [ ] Help sheets appear when clicked
- [ ] Empty state shows when no services connected
- [ ] Error handling works with invalid credentials
- [ ] Console shows appropriate logs
- [ ] Notifications permission is requested
- [ ] App persists between launches

## Next Steps

Once basic functionality is verified:
1. Test with real credentials (if available)
2. Test widget functionality (requires Xcode project setup)
3. Test notification alerts
4. Test auto-refresh (verify a refresh after 10 minutes, then sleep for at
   least 10 minutes and wake to verify stale-data catch-up)
5. Test usage limit monitoring (wait 5 minutes)

## Common Issues

### "App doesn't appear in menu bar"
- Check that `LSUIElement` is `YES` in Info.plist
- Verify the app is actually running (Activity Monitor)
- Check Console for errors

### "Settings window doesn't open"
- The Settings button uses `NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)`
- This should work automatically with SwiftUI's `Settings` scene

### "No data appears"
- Verify you're authenticated in Settings
- Check console for API errors
- Verify network connectivity
- Check that services are returning data

---

## Automated smoke / e2e suite

The deterministic app-level smoke suite runs through SwiftPM (no Xcode UI
automation, no credentials — it drives the real `UsageDataManager` and the
widget rendering contract with fixtures).

**Single command:**

```bash
swift test --filter 'MenuBarSmokeTests|WidgetRenderingTests'
```

(Requires full Xcode — Command Line Tools lack the XCTest module. In CI the
whole suite runs via `scripts/check-coverage.sh`.)

**What it covers:**

- `MenuBarSmokeTests` — launch → inject fixture usage data → refresh → assert the
  metrics snapshot, the App Group widget-bridge file, the persisted cache blob,
  and refresh-interval persistence; plus relaunch-restores-cache.
- `WidgetRenderingTests` — small/medium/large widget layouts render non-empty rows
  for Claude Code, OpenAI Codex, and Cursor fixtures (view-model-level: validates
  the `MeterBarShared` data→presentation contract the widget renders from), stable
  sort order, and the empty state.

**CI:** the full suite runs on every PR (the `test` job) and once daily via the
scheduled `e2e.yml` workflow (fixtures only, no credentials).

## Manual widget QA checklist

The automated tests validate the widget's *data contract* but not its live
SwiftUI rendering (the extension target isn't in the SwiftPM package). Before a
release, verify the actual widget in the WidgetKit simulator / on the desktop for
each state:

- [ ] **Populated** — with all three providers connected, add the small, medium,
      and large widgets; each shows provider icons, progress bars, and `%` labels.
- [ ] **Single provider** — with only one provider enabled, the widget renders
      that one row without empty gaps.
- [ ] **Empty** — with no providers connected (fresh install / all hidden), small
      shows "No data", medium/large show "No services connected".
- [ ] **Stale** — leave the app closed past the refresh window; the widget keeps
      showing the last cached values (does not blank out).
- [ ] **Error** — revoke/expire a provider's auth; the widget continues to render
      the remaining providers rather than going fully empty.
- [ ] **Reload** — change the refresh interval or force a refresh in the app and
      confirm the widget updates (via `WidgetCenter.reloadTimelines`).
