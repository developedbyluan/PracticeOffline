import SwiftUI

/// Port of the toast in src/components/feedback/Toast.tsx (see docs/feedback-ui.md):
/// a dark rounded bar near the bottom for errors and short notices. It hides itself
/// after 4 seconds, and a tap hides it right away. A new toast replaces the one on screen.
@MainActor @Observable
final class Toast {
    static let shared = Toast()

    private(set) var message: String?
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    private init() {}

    static func show(_ message: String) {
        shared.show(message)
    }

    func show(_ message: String) {
        withAnimation(.snappy) { self.message = message }
        AccessibilityNotification.Announcement(message).post()
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        withAnimation(.snappy) { message = nil }
    }
}

/// Shows the current toast. Mounted around the tabs, and around the player sheet
/// (a sheet covers the tabs' toast).
struct ToastHost: ViewModifier {
    /// How far above the bottom edge it sits, e.g. to clear the tab bar.
    var bottomPadding: CGFloat = 64
    @State private var toast = Toast.shared

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message = toast.message {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle")
                    Text(message)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(.white)
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .background(Color(white: 0.11), in: .rect(cornerRadius: 12))
                .padding(.horizontal, 16)
                .padding(.bottom, bottomPadding)
                .onTapGesture { toast.hide() }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(message)
            }
        }
    }
}

extension View {
    func toastHost(bottomPadding: CGFloat = 64) -> some View {
        modifier(ToastHost(bottomPadding: bottomPadding))
    }
}
