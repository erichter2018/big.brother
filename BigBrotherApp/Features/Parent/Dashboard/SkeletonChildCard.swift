import SwiftUI

/// Placeholder skeleton card shown while the dashboard is loading.
/// Mimics the ChildSummaryCard layout with shimmer animation.
struct SkeletonChildCard: View {
    @State private var shimmerPhase: CGFloat = -1

    var body: some View {
        HStack(spacing: 12) {
            // Avatar placeholder
            Circle()
                .fill(.quaternary)
                .frame(width: 56, height: 56)

            // Text lines
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .frame(width: 100, height: 14)
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .frame(width: 160, height: 10)
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .frame(width: 80, height: 10)
            }

            Spacer(minLength: 0)

            // Pill button placeholder
            Capsule()
                .fill(.quaternary)
                .frame(width: 70, height: 32)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            shimmerOverlay
                .clipShape(RoundedRectangle(cornerRadius: 16))
        )
        .onAppear {
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                shimmerPhase = 1
            }
        }
        .accessibilityHidden(true)
    }

    private var shimmerOverlay: some View {
        GeometryReader { geo in
            let width = geo.size.width
            LinearGradient(
                colors: [.clear, .white.opacity(0.08), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: width * 0.6)
            .offset(x: width * shimmerPhase)
        }
    }
}
