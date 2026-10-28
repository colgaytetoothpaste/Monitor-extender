import SwiftUI
import AVKit
import WebKit

// MARK: - App entry point

@main
struct LinkPlayerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

// Tells iOS we want our own window on the external display (instead of mirroring)
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        if connectingSceneSession.role == .windowExternalDisplayNonInteractive {
            config.delegateClass = ExternalSceneDelegate.self
        }
        return config
    }
}

final class ExternalSceneDelegate: UIResponder, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        ExternalDisplay.shared.attach(to: windowScene)
    }
    func sceneDidDisconnect(_ scene: UIScene) {
        ExternalDisplay.shared.detach()
    }
}

// MARK: - External display (monitor) player

final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

final class ExternalPlayerVC: UIViewController {
    let player: AVPlayer
    init(player: AVPlayer) {
        self.player = player
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func loadView() {
        let v = PlayerLayerView()
        v.backgroundColor = .black
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect   // use .resizeAspectFill to crop-fill
        view = v
    }
}

final class ExternalDisplay: ObservableObject {
    static let shared = ExternalDisplay()
    @Published var isConnected = false
    @Published var isPlaying = false

    let player = AVPlayer()
    private var window: UIWindow?

    init() { player.allowsExternalPlayback = false }

    func attach(to scene: UIWindowScene) {
        let w = UIWindow(windowScene: scene)
        w.rootViewController = ExternalPlayerVC(player: player)
        w.isHidden = false
        window = w
        DispatchQueue.main.async { self.isConnected = true }
    }

    func detach() {
        window?.isHidden = true
        window = nil
        player.pause()
        DispatchQueue.main.async {
            self.isConnected = false
            self.isPlaying = false
        }
    }

    func play(_ url: URL) {
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.play()
        isPlaying = true
    }

    func toggle() {
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    func skip(_ seconds: Double) {
        let target = max(0, player.currentTime().seconds + seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
    }
}

// Phone screen while the video plays on the monitor: just a remote control
struct ExternalRemoteView: View {
    @ObservedObject var display = ExternalDisplay.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 28) {
            HStack {
                Button { display.stop(); dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title)
                }
                Spacer()
            }
            Spacer()
            Image(systemName: "tv").font(.system(size: 60))
            Text("Playing on external display").font(.headline)
            HStack(spacing: 40) {
                Button { display.skip(-10) } label: { Image(systemName: "gobackward.10") }
                Button { display.toggle() } label: {
                    Image(systemName: display.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 72))
                }
                Button { display.skip(10) } label: { Image(systemName: "goforward.10") }
            }
            .font(.largeTitle)
            Spacer()
        }
        .padding()
        .foregroundStyle(.white)
        .background(Color.black.ignoresSafeArea())
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

// MARK: - Routing

struct Destination: Identifiable {
    enum Kind { case phoneVideo, remote, browser }
    let id = UUID()
    let url: URL
    let kind: Kind
}

// MARK: - Main screen

struct ContentView: View {
    @ObservedObject private var external = ExternalDisplay.shared
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
            Text("Paste a video link. With a monitor connected, the video plays on the monitor only.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Label(external.isConnected ? "Monitor connected" : "No monitor detected",
                  systemImage: external.isConnected ? "checkmark.circle.fill" : "xmark.circle")
                .font(.footnote)
                .foregroundStyle(external.isConnected ? .green : .secondary)

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
            switch dest.kind {
            case .phoneVideo: FullScreenPlayerView(url: dest.url)
            case .remote:     ExternalRemoteView()
            case .browser:    BrowserView(url: dest.url)
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

        let isDirect = ["mp4", "mov", "m4v", "m3u8"].contains(url.pathExtension.lowercased())
        if isDirect && external.isConnected {
            external.play(url)
            destination = Destination(url: url, kind: .remote)
        } else if isDirect {
            destination = Destination(url: url, kind: .phoneVideo)
        } else {
            destination = Destination(url: url, kind: .browser)
        }
    }
}

// MARK: - Direct video on the phone (used when no monitor is connected)

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

// MARK: - Websites: built-in browser

final class WebController: NSObject, ObservableObject, WKScriptMessageHandler {
    let webView: WKWebView
    @Published var showRemote = false
    @Published var alertText: String?

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = false
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.userContentController.addUserScript(
            WKUserScript(source: WebController.injectedJS,
                         injectionTime: .atDocumentEnd,
                         forMainFrameOnly: false))
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        config.userContentController.add(self, name: "lp")
    }

    // The tv button inside a page sends the video's address here
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let s = message.body as? String,
              let url = URL(string: s),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            alertText = "This site hides its video file, so it can't be sent to the monitor. Try a direct .mp4 or .m3u8 link."
            return
        }
        if ExternalDisplay.shared.isConnected {
            ExternalDisplay.shared.play(url)
            showRemote = true
        } else {
            alertText = "No external display detected."
        }
    }

    static let injectedJS = #"""
    (function () {
      if (window.__lp) return; window.__lp = true;
      function biggest() {
        var v = [].slice.call(document.querySelectorAll('video'));
        v.sort(function (a, b) { return b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight; });
        return v[0];
      }
      function mk(label, top, fn) {
        var b = document.createElement('div');
        b.textContent = label;
        b.style.cssText = 'position:fixed;top:' + top + 'px;right:12px;z-index:2147483647;width:40px;height:40px;' +
          'line-height:40px;text-align:center;font-size:20px;color:#fff;background:rgba(0,0,0,.6);' +
          'border-radius:20px;display:none;font-family:-apple-system,sans-serif;';
        b.addEventListener('click', function (e) { e.stopPropagation(); fn(); });
        (document.body || document.documentElement).appendChild(b);
        return b;
      }
      var full = mk('\u26F6', 12, function () {
        var v = biggest(); if (!v) return;
        try { v.play(); } catch (e) {}
        try { v.webkitEnterFullscreen(); } catch (e) {}
      });
      var tv = mk('\uD83D\uDCFA', 60, function () {
        var v = biggest(); if (!v) return;
        var src = v.currentSrc || v.src || '';
        try { v.pause(); } catch (e) {}
        window.webkit.messageHandlers.lp.postMessage(src);
      });
      setInterval(function () {
        var v = biggest();
        var show = (v && v.clientWidth > 120 && v.clientHeight > 80) ? 'block' : 'none';
        full.style.display = show; tv.style.display = show;
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
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            WebViewRepresentable(controller: controller, url: url)
        }
        .fullScreenCover(isPresented: $controller.showRemote) { ExternalRemoteView() }
        .alert("Can't send to monitor",
               isPresented: Binding(get: { controller.alertText != nil },
                                    set: { if !$0 { controller.alertText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(controller.alertText ?? "")
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
