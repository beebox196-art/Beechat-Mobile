import SwiftUI

public struct StreamingIndicatorView: View {
    @State private var dotCount = 1
    let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .opacity(i < dotCount ? 1.0 : 0.3)
            }
        }
        .onReceive(timer) { _ in
            dotCount = (dotCount % 3) + 1
        }
    }
}
