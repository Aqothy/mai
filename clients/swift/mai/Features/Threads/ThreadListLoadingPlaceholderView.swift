import SwiftUI

/// Skeleton rows shown while the thread-list snapshot loads.
struct ThreadListLoadingPlaceholderView: View {
    // Widths double as ForEach identity, so they must stay unique.
    private static let titleWidths: [CGFloat] = [236, 180, 268, 152, 244, 208, 190]

    var body: some View {
        VStack(alignment: .leading) {
            ForEach(Self.titleWidths, id: \.self) { titleWidth in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Capsule()
                            .frame(width: titleWidth, height: 14)
                        Spacer()
                        Capsule()
                            .frame(width: 26, height: 10)
                    }
                    Capsule()
                        .frame(width: 132, height: 10)
                }
                .padding(EdgeInsets(top: 10, leading: 16, bottom: 12, trailing: 16))

                Divider()
                    .padding(.leading, 16)
            }
        }
        .foregroundStyle(.quaternary)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading Chats")
    }
}

#if DEBUG
#Preview("Thread List Loading Placeholder") {
    ThreadListLoadingPlaceholderView()
}
#endif
