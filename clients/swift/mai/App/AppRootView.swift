import SwiftUI

struct AppRootView: View {
    var body: some View {
        #if os(iOS)
        IOSAppContainer()
        #else
        DesktopAppContainer()
        #endif
    }
}
