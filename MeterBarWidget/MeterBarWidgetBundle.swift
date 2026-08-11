//
//  MeterBarWidgetBundle.swift
//  MeterBarWidget
//
//  Created by Genfeed AI on 29/12/2025.
//

import WidgetKit
import SwiftUI

@main
struct MeterBarWidgetBundle: WidgetBundle {
    var body: some Widget {
        UsageWidget()
        BurnDownWidget()
    }
}
