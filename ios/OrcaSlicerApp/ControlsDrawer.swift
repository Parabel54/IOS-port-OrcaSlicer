import SwiftUI
import UIKit

/// A nonmodal drawer keeps the model interactive; dragging its grabber moves
/// between full controls, quick actions and a handle-only view.
struct ControlsDrawer: View {
    let expandedHeight: CGFloat
    let bottomInset: CGFloat
    let title: String
    let compact: () -> AnyView
    let expanded: () -> AnyView
    @State private var position: Position = .compact
    @GestureState private var drag: CGFloat = 0

    private enum Position: Equatable { case hidden, compact, expanded }
    private var hiddenHeight: CGFloat { 32 + min(bottomInset, 16) }
    private var compactHeight: CGFloat { 88 + min(bottomInset, 16) }
    private var fullHeight: CGFloat { max(compactHeight, min(expandedHeight, 440)) }
    private var restingHeight: CGFloat {
        switch position {
        case .hidden: return hiddenHeight
        case .compact: return compactHeight
        case .expanded: return fullHeight
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Capsule().fill(Color.secondary).frame(width: 36, height: 4)
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        position = position == .hidden ? .compact : .hidden
                    }
                } label: {
                    Image(systemName: position == .hidden ? "chevron.up" : "chevron.down")
                        .frame(width: 32, height: 30)
                }
                .accessibilityLabel(position == .hidden ? Text("Show controls") : Text("Hide controls"))
            }
            .padding(.horizontal, 14)
            .frame(height: 32)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 8)
                .updating($drag) { value, state, _ in state = value.translation.height }
                .onEnded { value in
                    withAnimation(.easeOut(duration: 0.2)) {
                        if value.translation.height > 100 { position = .hidden }
                        else if value.translation.height > 30 { position = position == .expanded ? .compact : .hidden }
                        else if value.translation.height < -30 { position = .expanded }
                    }
                })
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.2)) { position = position == .expanded ? .compact : .expanded }
            }
            .accessibilityElement(children: .contain)
            .accessibilityAdjustableAction { direction in
                withAnimation(.easeOut(duration: 0.2)) {
                    switch direction {
                    case .increment: position = .expanded
                    case .decrement: position = .hidden
                    @unknown default: break
                    }
                }
            }

            if position != .hidden || drag < -15 {
                if position == .expanded || drag < -40 {
                    expanded().frame(maxHeight: .infinity)
                } else {
                    compact().frame(maxHeight: .infinity)
                }
            }
        }
        .padding(.bottom, min(bottomInset, 16))
        .frame(height: min(max(restingHeight - drag, hiddenHeight), fullHeight), alignment: .top)
        .background(Color(UIColor.secondarySystemBackground))
        .clipShape(UnevenDrawerShape())
    }
}

private struct UnevenDrawerShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(roundedRect: rect, byRoundingCorners: [.topLeft, .topRight],
                          cornerRadii: CGSize(width: 18, height: 18)).cgPath)
    }
}
