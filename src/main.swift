import Cocoa
import WebKit
import Network

// A tiny localhost HTTP server that serves one HTML document on a fixed port.
// Fixed port = stable web origin, so the page's localStorage (tasks, language,
// the drag hint) persists across launches — file:// would not.
final class MiniServer {
    private let html: Data
    private var listener: NWListener?
    let port: UInt16

    init?(html: Data, port: UInt16) {
        self.html = html
        self.port = port
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            return nil
        }
    }

    func start() {
        listener?.newConnectionHandler = { [weak self] conn in
            guard let self = self else { return }
            conn.start(queue: .global())
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { _, _, _, _ in
                var header = "HTTP/1.1 200 OK\r\n"
                header += "Content-Type: text/html; charset=utf-8\r\n"
                header += "Content-Length: \(self.html.count)\r\n"
                header += "Cache-Control: no-cache\r\n"
                header += "Connection: close\r\n\r\n"
                var resp = Data(header.utf8)
                resp.append(self.html)
                conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        listener?.start(queue: .global())
    }
}

// WKWebView that lets ⌘-drag move the window (so normal drags still tear the
// calendar sheet) and responds to clicks even when the app isn't frontmost.
final class DragWebView: WKWebView {
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            window?.performDrag(with: event)
            return
        }
        super.mouseDown(with: event)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler {
    var window: NSWindow!
    var webView: DragWebView!
    var server: MiniServer?
    var statusItem: NSStatusItem!
    let port: UInt16 = 39217

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let htmlData: Data
        if let url = Bundle.main.url(forResource: "app", withExtension: "html"),
           let d = try? Data(contentsOf: url) {
            htmlData = d
        } else {
            htmlData = Data("<h1 style='font-family:sans-serif'>app.html not found</h1>".utf8)
        }

        server = MiniServer(html: htmlData, port: port)
        server?.start()

        // Size: a tall, narrow widget — this width triggers the page's stacked
        // (mobile) layout so the calendar, Tết countdown and tasks stack nicely.
        let w: CGFloat = 432
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let h: CGFloat = min(840, screen.height - 40)
        // Start centered so it's easy to find; ⌘-drag to move and it's remembered.
        let originX = screen.midX - w / 2
        let originY = screen.midY - h / 2

        window = NSWindow(contentRect: NSRect(x: originX, y: originY, width: w, height: h),
                          styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        // Inject a close (×) button into the page — a visible, always-available
        // way to quit, on top of ⌘Q/⌘W and the menu-bar item.
        let ucc = WKUserContentController()
        ucc.add(self, name: "closeApp")
        let closeJS = """
        (function(){
          if (window.__lbClose) return; window.__lbClose = true;
          var st = document.createElement('style');
          st.textContent = '.topbar{padding-right:52px !important;}';
          (document.head || document.documentElement).appendChild(st);
          function add(){
            if(!document.body){ return setTimeout(add,40); }
            var b = document.createElement('button');
            b.textContent = '\\u00D7';
            b.setAttribute('aria-label','Đóng widget / Close');
            b.title = 'Đóng widget  (⌘Q)';
            b.style.cssText = 'position:fixed;top:12px;right:12px;z-index:99999;width:30px;height:30px;border-radius:50%;border:1px solid rgba(231,199,104,.55);background:rgba(40,14,14,.6);color:#e7c768;font:600 17px/27px system-ui,-apple-system,sans-serif;text-align:center;cursor:pointer;padding:0;-webkit-backdrop-filter:blur(5px);';
            b.addEventListener('mouseenter',function(){b.style.background='rgba(196,30,42,.92)';b.style.color='#fff';});
            b.addEventListener('mouseleave',function(){b.style.background='rgba(40,14,14,.6)';b.style.color='#e7c768';});
            b.addEventListener('click',function(){ try{ window.webkit.messageHandlers.closeApp.postMessage('quit'); }catch(e){} });
            document.body.appendChild(b);
          }
          add();
        })();
        """
        ucc.addUserScript(WKUserScript(source: closeJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController = ucc

        webView = DragWebView(frame: NSRect(x: 0, y: 0, width: w, height: h), configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.wantsLayer = true
        webView.layer?.cornerRadius = 22
        webView.layer?.masksToBounds = true
        webView.autoresizingMask = [.width, .height]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        container.wantsLayer = true
        container.addSubview(webView)
        window.contentView = container

        if let url = URL(string: "http://127.0.0.1:\(port)/") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.webView.load(URLRequest(url: url))
            }
        }
        window.setFrameAutosaveName("LichBlocWidget") // remember where it's dragged
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)

        setupStatusItem()

        // Keyboard quit: ⌘Q / ⌘W close the widget when it's focused.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.command),
               let k = event.charactersIgnoringModifiers?.lowercased(), k == "q" || k == "w" {
                NSApp.terminate(nil)
                return nil
            }
            return event
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "closeApp" { NSApp.terminate(nil) }
    }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "曆"
        let menu = NSMenu()
        let reload = NSMenuItem(title: "Reload Calendar", action: #selector(reloadCal), keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Lịch Bloc", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc func reloadCal() { webView.reload() }
    @objc func quitApp() { NSApp.terminate(nil) }
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
