// ScribeiOS/System/ScribeSystemIntegrationModifier.swift
//
// `.scribeSystemIntegration()` — applied once to each scene's root view
// (ScribeiOSApp). Starts IOSSystemIntegration, forwards scene activation /
// backgrounding to it, presents the Quick Capture sheet in the first active
// scene and shows its banners ("Saved “…” to your notes" · Show).

import SwiftUI

extension View {
    /// Widgets, Share-extension import, Spotlight and Quick Capture for this
    /// scene (see IOSSystemIntegration).
    func scribeSystemIntegration() -> some View {
        modifier(ScribeSystemIntegrationModifier())
    }
}

struct ScribeSystemIntegrationModifier: ViewModifier {

    @Environment(\.scenePhase) private var scenePhase
    @State private var captureRequest: IOSQuickCaptureRequest?

    func body(content: Content) -> some View {
        content
            .onAppear {
                IOSSystemIntegration.shared.start()
                claimCaptureIfActive()
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    IOSSystemIntegration.shared.sceneDidBecomeActive()
                    claimCaptureIfActive()
                case .background:
                    IOSSystemIntegration.shared.sceneDidEnterBackground()
                default:
                    break
                }
            }
            .onChange(of: IOSQuickCaptureCenter.shared.pending?.id) { _, _ in
                claimCaptureIfActive()
            }
            .sheet(item: $captureRequest) { request in
                IOSQuickCaptureSheet(kind: request.kind)
            }
            .overlay(alignment: .top) {
                if let banner = IOSSystemIntegration.shared.banner {
                    IOSSystemBannerView(banner: banner)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: IOSSystemIntegration.shared.banner?.id)
    }

    private func claimCaptureIfActive() {
        guard scenePhase == .active, captureRequest == nil,
              IOSQuickCaptureCenter.shared.pending != nil,
              let request = IOSQuickCaptureCenter.shared.claim() else { return }
        captureRequest = request
    }
}

/// The floating banner.
struct IOSSystemBannerView: View {

    let banner: IOSSystemBanner

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(banner.isError ? Color.orange : Color.green)
            Text(banner.message)
                .font(.subheadline)
                .lineLimit(2)
            Spacer(minLength: 4)
            if let link = banner.link {
                Button("Show") {
                    IOSSystemIntegration.shared.dismissBanner()
                    IOSSystemIntegration.openInApp(link)
                }
                .font(.subheadline.weight(.semibold))
            }
            Button {
                IOSSystemIntegration.shared.dismissBanner()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .frame(maxWidth: 520)
    }
}
