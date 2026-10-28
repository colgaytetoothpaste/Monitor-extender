import SwiftUI
import AVKit
import WebKit

// MARK: - App entry point

@main
struct LinkPlayerApp: App {
    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

// MARK: - Routing

struct Destination: Identifiable {
    let id = UUID()
    let url: URL
    var isDirectVideo: Bool {
        ["mp4", "mov", "m4v", "m3u8"].contains(url.pathExtension.lowercased())
    }
}

// MARK: - Main screen

struct ContentView: View {
    @State private var urlText = ""
    @State private var destination: Destination?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Link Player").font(.largeTitle.bold())
            Text("Paste any video or website link. Videos open full screen.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            HStack {
                TextField("Paste a link", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit(play)
                Button {
                    if let clip = UIPasteboard.general.string { urlText = clip }
                } label: { Image(systemName: "doc.on.clipboard") }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)

            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.red)
            }

            Button(action: play) {
                Label("Play Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal)
            Spacer()
        }
        .fullScreenCover(item: $destination) { dest in
            if dest.isDirectVideo {
                FullScreenPlayerView(url: dest.url)
            } else {
                BrowserView(url: dest.url)
            }
        }
    }

    private func play() {
        errorMessage = nil
        var text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host, host.contains(".") else {
            errorMessage = "Please enter a valid link."
            return
        }
        destination = Destination(url: url)
    }
}

// MARK: - Direct video: native full screen player

struct FullScreenPlayerView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            PlayerViewController(url: url).ignoresSafeArea()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.5))
                    .padding(16)
            }
        }
        .statusBarHidden(true)
    }
}

struct PlayerViewController: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        let player = AVPlayer(url: url)
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        controller.player = player
        controller.videoGravity = .resizeAspect
        controller.entersFullScreenWhenPlaybackBegins = true
        controller.allowsPictureInPicturePlayback = true
        player.play()
        return controller
    }
    func updateUIViewController(_ c: AVPlayerViewController, context: Context) {}
    static func dismantleUIViewController(_ c: AVPlayerViewController, coordinator: ()) {
        c.player?.pause()
        c.player = nil
    }
}

// MARK: - Any website: built-in browser that sends videos to native full screen

final class WebController: ObservableObject {
    let webView: WKWebView

    init() {
        let config = WKWebViewConfiguration()
        // false = on iPhone, any <video> that starts playing opens in native full screen
        config.allowsInlineMediaPlayback = false
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        // Runs in every frame (including embedded iframes) so it finds videos anywhere
        let script = WKUserScript(source: WebController.injectedJS,
                                  injectionTime: .atDocumentEnd,
                                  forMainFrameOnly: false)
        config.userContentController.addUserScript(script)

        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
    }

    func goFullScreen() {
        webView.evaluateJavaScript("window.__lpFull && window.__lpFull()")
    }

    // Adds a floating "full screen" button inside any frame that contains a sizeable video.
    // Tapping it is a real user gesture, so iOS allows full screen even for cross-origin iframes.
    static let injectedJS = #"""
    (function () {
      if (window.__lp) return; window.__lp = true;
      function biggest() {
        var v = [].slice.call(document.querySelectorAll('video'));
        v.sort(function (a, b) { return b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight; });
        return v[0];
      }
      window.__lpFull = function () {
        var v = biggest(); if (!v) return false;
        try { v.play(); } catch (e) {}
        try { v.webkitEnterFullscreen(); } catch (e) {}
        return true;
      };
      var btn = document.createElement('div');
      btn.textContent = '\u26F6';
      btn.style.cssText = 'position:fixed;top:12px;right:12px;z-index:2147483647;width:40px;height:40px;' +
        'line-height:40px;text-align:center;font-size:22px;color:#fff;background:rgba(0,0,0,.6);' +
        'border-radius:20px;display:none;font-family:-apple-system,sans-serif;';
      btn.addEventListener('click', function (e) { e.stopPropagation(); window.__lpFull(); });
      (document.body || document.documentElement).appendChild(btn);
      setInterval(function () {
        var v = biggest();
        btn.style.display = (v && v.clientWidth > 120 && v.clientHeight > 80) ? 'block' : 'none';
      }, 1000);
    })();
    """#
}

struct BrowserView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = WebController()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                Button { controller.webView.goBack() } label: { Image(systemName: "chevron.left") }
                Button { controller.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                Spacer()
                Button { controller.goFullScreen() } label: {
                    Label("Fullscreen video", systemImage: "arrow.up.left.and.arrow.down.right")
                        .labelStyle(.titleAndIcon)
                        .font(.footnote.bold())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            WebViewRepresentable(controller: controller, url: url)
        }
    }
}

struct WebViewRepresentable: UIViewRepresentable {
    let controller: WebController
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        controller.webView.load(URLRequest(url: url))
        return controller.webView
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
