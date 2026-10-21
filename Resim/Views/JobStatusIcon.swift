import SwiftUI

struct JobStatusIcon: View {
    let state: JobState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Group {
                if state == .running {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                } else {
                    Image(systemName: state.symbol)
                        .foregroundStyle(state.tint)
                }
            }
            .id(state)
            .transition(reduceMotion ? .identity : .modifier(
                active: IconSwapProgress(progress: 0),
                identity: IconSwapProgress(progress: 1)))
        }
        .frame(width: 14, height: 16)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: state)
        // The table row already announces the file and its processing state.
        .accessibilityHidden(true)
    }
}

private nonisolated struct IconSwapProgress: AnimatableModifier {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .scaleEffect(0.25 + 0.75 * progress)
            .blur(radius: 2 * (1 - progress))
    }
}
