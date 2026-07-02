// W4 Memory Probe (iOS) — companion to BeeChat-v5/Experiments/W4MemoryProbe (macOS).
// Same question, tighter budget: does ScrollView + LazyVStack + per-bubble web views
// stay under jetsam-safe limits on a 4 GB device? Desktop stressors (window resize)
// are replaced by the iOS ones: Dynamic Type changes, rotation, and memory warnings.
//
// Build: xcodegen && open W4MemoryProbeiOS.xcodeproj, run on the OLDEST device you
// support (iPhone SE class). Simulator numbers are indicative only — jetsam limits
// and WebContent behavior differ on device. Thresholds: see README.md.

import SwiftUI
import MarkdownWebView

// MARK: - Sample corpus (same mix as the macOS probe)

let corpus: [String] = {
    let templates = [
        "Quick answer: the gateway reconnects automatically after **\(Int.random(in: 2...9))s**. Nothing to do on your side.",

        """
        Here's the fix for the crash:

        ```swift
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            templateReady = false
            webView.loadHTMLString(template, baseURL: nil)
        }
        ```

        The WebContent process was dying under memory pressure and the bubble stayed blank.
        """,

        """
        | Component | Tests | Status |
        |-----------|-------|--------|
        | Persistence | 27 | ✅ |
        | Gateway | 48 | ✅ |
        | SyncBridge | 37 | ✅ |
        | App | 14 | ✅ |
        """,

        """
        Three options, ranked:

        1. **Native conversion** — best memory, best a11y
        2. *Single web view* — good perf, high maintenance
           - requires DOM windowing
           - loses native selection
        3. Per-bubble web view — simplest to start, worst at scale

        > On iOS the ceiling is jetsam, not user patience.
        """,

        String(repeating: "This is a longer paragraph of ordinary prose to vary bubble heights. ",
               count: Int.random(in: 3...12)),
    ]
    return (0..<500).map { i in "**Message \(i)** — \(templates[i % templates.count])" }
}()

// MARK: - Memory readout (phys_footprint — same metric jetsam uses)

func physFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return -1 }
    return Double(info.phys_footprint) / 1_048_576
}

// MARK: - Probe UI

enum Renderer: String, CaseIterable {
    case webview = "markdown-webview"
    case native = "native Text"
}

struct ProbeView: View {
    @State private var renderer: Renderer = .webview
    @State private var footprint = physFootprintMB()
    @State private var peak: Double = 0
    @State private var autoScrolling = false
    @State private var memoryWarnings = 0
    // iOS counterpart of the macOS resize test: force reflow via type size.
    @State private var typeSize: DynamicTypeSize = .large

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(corpus.indices, id: \.self) { i in
                            bubble(corpus[i])
                                .padding(.horizontal, 12)
                                .id(i)
                        }
                    }
                    .padding(.vertical, 12)
                }
                .dynamicTypeSize(typeSize)
                .navigationTitle("W4 iOS")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Picker("Renderer", selection: $renderer) {
                            ForEach(Renderer.allCases, id: \.self) { Text($0.rawValue) }
                        }
                        .pickerStyle(.segmented)
                        Button(autoScrolling ? "…" : "Scroll") { autoScroll(proxy) }
                            .disabled(autoScrolling)
                        // Cycle type size: the reflow stress test (all live bubbles
                        // re-lay-out and re-report heights, like macOS window resize)
                        Button("Aa") {
                            typeSize = typeSize == .large ? .accessibility3 : .large
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Text(String(format: "%.0f MB · pk %.0f · ⚠︎%d",
                                    footprint, peak, memoryWarnings))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(memoryWarnings > 0 ? .red : .primary)
                    }
                }
            }
        }
        .onReceive(timer) { _ in
            footprint = physFootprintMB()
            peak = max(peak, footprint)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            memoryWarnings += 1
        }
    }

    @ViewBuilder
    private func bubble(_ content: String) -> some View {
        Group {
            switch renderer {
            case .webview:
                MarkdownWebView(content)
            case .native:
                Text((try? AttributedString(
                    markdown: content,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                    ?? AttributedString(content))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
    }

    private func autoScroll(_ proxy: ScrollViewProxy) {
        autoScrolling = true
        Task { @MainActor in
            for i in stride(from: 0, through: corpus.count - 1, by: 10) {
                withAnimation(.linear(duration: 0.3)) { proxy.scrollTo(i, anchor: .top) }
                try? await Task.sleep(for: .milliseconds(500))
            }
            autoScrolling = false
        }
    }
}

@main
struct W4MemoryProbeApp: App {
    var body: some Scene {
        WindowGroup { ProbeView() }
    }
}
