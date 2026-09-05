import SwiftUI

struct AppRootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            MacPastebinBackdrop()

            if appState.isLocked {
                UnlockView()
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.985)),
                            removal: .opacity.combined(with: .scale(scale: 1.035))
                        )
                    )
            } else {
                EditorView()
                    .zIndex(1)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.96)),
                            removal: .opacity.combined(with: .scale(scale: 0.985))
                        )
                    )
            }
        }
        .animation(
            .spring(response: 0.52, dampingFraction: 0.88, blendDuration: 0.12),
            value: appState.isLocked
        )
        .background {
            TransparentWindowView()
        }
        .containerBackground(.clear, for: .window)
        .frame(minWidth: 980, minHeight: 640)
    }
}
