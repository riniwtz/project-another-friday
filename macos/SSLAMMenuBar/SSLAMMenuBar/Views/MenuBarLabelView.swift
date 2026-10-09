import SwiftUI

struct MenuBarLabelView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 6) {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)

            ZStack(alignment: .leading) {
                Text(appState.tickerDisplayText)
                    .id(appState.tickerRevision)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 280, alignment: .leading)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        )
                    )
            }
            .frame(height: 16)
            .clipped()
        }
        .padding(.horizontal, 2)
        .accessibilityLabel("SSLAM detection")
        .accessibilityValue(appState.tickerDisplayText)
    }
}
