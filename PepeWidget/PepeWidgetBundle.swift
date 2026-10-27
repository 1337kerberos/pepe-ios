// Widget extension entry: only the Live Activity (no Home Screen widget yet).
import WidgetKit
import SwiftUI

@main
struct PepeWidgetBundle: WidgetBundle {
    var body: some Widget {
        PepeLiveActivity()
    }
}
