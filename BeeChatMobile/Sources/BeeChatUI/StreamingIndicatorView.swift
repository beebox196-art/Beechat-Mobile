import SwiftUI

public struct StreamingIndicatorView: View {
    @State private var dotCount = 1

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .opacity(i < dotCount ? 1.0 : 0.3)
            }
        }
        .onAppear {
            dotCount = 1
        }
    }
}