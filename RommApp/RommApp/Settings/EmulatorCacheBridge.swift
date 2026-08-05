import SwiftUI
@preconcurrency import WebKit

/// One entry in EmulatorJS's on-device ROM cache: the `EmulatorJS-roms`
/// IndexedDB database, object store `rom`, as shipped in EmulatorJS 4.2.3,
/// the version RomM 5.1.0 pins. Read directly rather than through
/// EmulatorJS's JS classes, this reimplements `EJS_STORAGE` from
/// `data/src/storage.js` at that exact tag, not guessed and not taken from
/// EmulatorJS's main branch: main has since replaced this whole schema
/// with an `EmulatorJS-Cache` database that 4.2.3 never opens, and the
/// first version of this bridge faithfully implemented that wrong one,
/// writing entries the real player could never see.
///
/// The store's key is the last path segment of the URL EmulatorJS
/// downloads from, query string included, exactly
/// `gameUrl.split("/").pop()`: for RomM that means something like
/// `Game%20Name.chd?file_ids=123`. The value is
/// `{ "content-length": <header string>, data: <ArrayBuffer> }`, with a
/// `type` field added for BIOS entries only, the main ROM entry carries
/// none.
struct CachedFile: Identifiable, Decodable {
    let key: String
    let type: String
    let fileSize: Int

    var id: String { key }

    /// The key with its query string stripped and percent-encoding
    /// undone, for display.
    var displayName: String {
        let base = key.split(separator: "?", maxSplits: 1).first.map(String.init) ?? key
        return base.removingPercentEncoding ?? base
    }
}

/// Everything the hidden bridge webview's own `console.log`/`warn`/`error`
/// produced, across whichever screen last used it (Settings > Cache,
/// Data Saver on a launch screen). Exists because the actual bottleneck
/// diagnosing the "stuck on Saving for later" bug was never a lack of
/// information, the injected scripts already logged plenty, it was the
/// friction of manually enabling Web Inspector, finding the right entry
/// in Safari's Develop menu, and reproducing live just to read it once.
/// Capturing it automatically means Debug's "Copy diagnostics" carries
/// the real trace without any of that next time.
enum BridgeConsoleLog {
    private static let key = "com.mmagtech.RommApp.bridgeConsoleLog"
    private static let limit = 60

    static func append(_ line: String) {
        var lines = recent
        lines.append(line)
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
        UserDefaults.standard.set(lines, forKey: key)
    }

    static var recent: [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// Reads, writes and deletes entries in EmulatorJS's on-device cache from
/// outside the player, for the Settings cache screen and Data Saver.
///
/// IndexedDB is scoped per origin, so this needs a real `WKWebView`
/// actually loaded on RomM's own origin, not a detached one: browsers will
/// not hand over another origin's storage to a blank or unattached
/// webview. The page loaded does not matter, EmulatorJS's cache is a
/// hardcoded database name (`EmulatorJS-roms`) independent of whatever
/// page happens to be showing, only the origin does.
@MainActor
final class EmulatorCacheBridge: NSObject, ObservableObject {
    @Published private(set) var files: [CachedFile] = []
    @Published private(set) var isReady = false
    @Published private(set) var loadError: String?

    private var webView: WKWebView?
    private var listContinuation: CheckedContinuation<[CachedFile], Never>?
    private var deleteContinuation: CheckedContinuation<Void, Never>?
    private var putContinuation: CheckedContinuation<(Bool, String?), Never>?

    func attach(_ webView: WKWebView) {
        self.webView = webView
    }

    func handleReady() {
        isReady = true
    }

    func handleLoadFailed() {
        loadError = "Couldn't reach the server to check the cache."
    }

    func handleList(_ json: String) {
        guard let data = json.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([CachedFile].self, from: data)
        else {
            listContinuation?.resume(returning: [])
            listContinuation = nil
            return
        }
        listContinuation?.resume(returning: decoded)
        listContinuation = nil
    }

    func handleDeleted() {
        deleteContinuation?.resume()
        deleteContinuation = nil
    }

    /// Called from the `cachePut` message handler once the script's own
    /// `done()` actually runs, meaning it got all the way through without
    /// throwing. Guarded against firing after `resolvePut` already
    /// answered via the timeout or a synchronous `evaluateJavaScript`
    /// error, `resolvePut` itself is idempotent for exactly that reason.
    func handlePut(_ success: Bool) {
        resolvePut(success, error: success ? nil : "The cache write failed inside the page.")
    }

    private func resolvePut(_ success: Bool, error: String?) {
        guard let continuation = putContinuation else { return }
        putContinuation = nil
        continuation.resume(returning: (success, error))
    }

    /// Writes a fresh entry into `EmulatorJS-roms`/`rom`, in the exact
    /// shape EmulatorJS 4.2.3's `downloadRom` cache check looks for.
    /// `url` must be the same relative path RomM's own player page would
    /// set as `EJS_gameUrl` (confirmed from RomM's frontend
    /// `getDownloadPath`): the store key is that URL's last path segment,
    /// query string included, computed here exactly as
    /// `gameUrl.split("/").pop()` does.
    ///
    /// `contentLength` matters as much as the key: on every launch,
    /// EmulatorJS sends one HEAD request for the game URL and only trusts
    /// the cached entry when the stored `content-length` string strictly
    /// equals the header from that live response. Pass the raw
    /// `Content-Length` header from the download that produced `data`,
    /// so the strings agree; a byte-count fallback is applied here when
    /// the header was missing. One consequence worth knowing: a cache hit
    /// still costs one HEAD request, a fully offline launch only works if
    /// that request fails in a way EmulatorJS treats as a miss... it does
    /// not, it downloads, so true offline play is not what this buys.
    /// What it buys is skipping the big transfer.
    ///
    /// Two failure modes get surfaced explicitly rather than left to hang,
    /// the actual bug found testing this against Dodonpachi II and Advance
    /// Wars 2, two very differently sized ROMs stuck identically on
    /// "Saving for later": a synchronous script error (caught by
    /// `evaluateJavaScript`'s own completion handler) and a silent stall
    /// inside the page that never calls `done()` at all (caught by a hard
    /// timeout). Either was previously indistinguishable from "still
    /// working."
    func put(url: String, type: String, contentLength: String?, data: Data) async -> (success: Bool, error: String?) {
        guard isReady, let webView else { return (false, "The cache bridge wasn't ready.") }
        var entry: [String: Any] = [
            "url": url, "type": type,
            "contentLength": contentLength ?? String(data.count),
            "base64": data.base64EncodedString(),
        ]
        // EmulatorJS's own main-ROM cache write stores no `type` field at
        // all, and its hit check reads the value without one; only
        // `downloadGameFile` (bios, patch, parent) writes and checks
        // `type`. Mirror that: omit the field for roms.
        if type == "rom" { entry.removeValue(forKey: "type") }
        guard let entryJSON = try? JSONSerialization.data(withJSONObject: entry),
            let entryString = String(data: entryJSON, encoding: .utf8)
        else { return (false, "Couldn't prepare the file to send to the cache.") }

        return await withCheckedContinuation { (continuation: CheckedContinuation<(Bool, String?), Never>) in
            putContinuation = continuation
            webView.evaluateJavaScript(Self.putScript(entryJSON: entryString)) { [weak self] _, error in
                if let error {
                    Task { @MainActor in
                        self?.resolvePut(false, error: "Script error: \(error.localizedDescription)")
                    }
                }
                // No error here only means the script started without a
                // syntax problem; IndexedDB itself is async, so the real
                // outcome still comes from `done()` via `handlePut`, or
                // from the timeout below if that never arrives.
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                self.resolvePut(false, error: "Timed out waiting for the cache to respond.")
            }
        }
    }

    /// Deletes the databases EmulatorJS can rebuild on its own: the core
    /// cache, and the legacy EmulatorJS-Cache a wrong-schema bridge once
    /// wrote. Never the roms cache, states, or saves.
    ///
    /// Exists because of a real failure found 2026-08-05: installing a
    /// build over a running game killed the WebContent process
    /// mid-transaction and wedged EmulatorJS-core, after which every boot
    /// hung forever at the exact point EmulatorJS reads that database to
    /// check for a cached core, one fetch after cores/reports/<core>.json
    /// in the network log. A wedged IndexedDB read never resolves and
    /// never errors, so nothing downstream can time it out; deleting the
    /// database is the repair, and cores simply redownload.
    func repairPlayerStorage() async {
        guard isReady, let webView else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            deleteContinuation = continuation
            webView.evaluateJavaScript(Self.repairScript)
        }
    }

    private static let repairScript = """
    (function () {
        var finished = false;
        function done() {
            if (finished) return;
            finished = true;
            window.webkit.messageHandlers.cacheDeleted.postMessage(true);
        }
        var pending = 2;
        function step() { pending -= 1; if (pending <= 0) done(); }
        ["EmulatorJS-core", "EmulatorJS-Cache"].forEach(function (name) {
            try {
                console.log("[repair] deleting", name);
                var req = indexedDB.deleteDatabase(name);
                req.onsuccess = function () { console.log("[repair] deleted", name); step(); };
                req.onerror = function () { console.error("[repair] delete failed", name, req.error); step(); };
                req.onblocked = function () { console.error("[repair] delete blocked", name); step(); };
            } catch (e) { step(); }
        });
        // A wedged database can hang even its own deletion callbacks;
        // reporting done after a hard timeout beats hanging the button.
        setTimeout(done, 8000);
    })();
    """

    func refresh() async {
        guard isReady, let webView else { return }
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<[CachedFile], Never>) in
            listContinuation = continuation
            webView.evaluateJavaScript(Self.listScript)
        }
        files = result.sorted { $0.fileSize > $1.fileSize }
    }

    func delete(_ file: CachedFile) async {
        guard isReady, let webView else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            deleteContinuation = continuation
            webView.evaluateJavaScript(Self.deleteScript(key: file.key))
        }
        files.removeAll { $0.id == file.id }
    }

    func deleteAll() async {
        for file in files {
            await delete(file)
        }
    }

    /// Mirrors `EJS_STORAGE`'s own `onupgradeneeded`: one keyless object
    /// store, no indexes. Needed on every open here for the same reason
    /// EmulatorJS has it on every open: whichever connection creates the
    /// database first must stamp the store, or later opens at the same
    /// version never get a second chance to add it.
    private static let openDatabaseJS = """
        function openRomsDB(onDB, onFail) {
            var open = indexedDB.open("EmulatorJS-roms", 1);
            open.onerror = function () { onFail(open.error); };
            open.onupgradeneeded = function () {
                var db = open.result;
                if (!db.objectStoreNames.contains("rom")) db.createObjectStore("rom");
            };
            open.onsuccess = function () {
                var db = open.result;
                if (!db.objectStoreNames.contains("rom")) { db.close(); onFail("no rom store"); return; }
                onDB(db);
            };
        }
        """

    /// A previous version of this bridge wrote everything into an
    /// `EmulatorJS-Cache` database that the shipped player never reads.
    /// Those entries are dead weight, up to hundreds of megabytes of it,
    /// so every list pass quietly drops the whole database. Harmless once
    /// it's gone: deleting a nonexistent database succeeds.
    private static let dropLegacyDatabaseJS = """
        try { indexedDB.deleteDatabase("EmulatorJS-Cache"); } catch (e) {}
        """

    private static let listScript = """
    (function () {
        \(dropLegacyDatabaseJS)
        \(openDatabaseJS)
        function post(items) {
            window.webkit.messageHandlers.cacheList.postMessage(JSON.stringify(items));
        }
        openRomsDB(function (db) {
            function finish(items) { db.close(); post(items); }
            var store = db.transaction("rom", "readonly").objectStore("rom");
            var keysReq = store.get("?EJS_KEYS!");
            keysReq.onerror = function () { finish([]); };
            keysReq.onsuccess = function () {
                var keys = keysReq.result || [];
                if (keys.length === 0) { finish([]); return; }
                var items = [];
                var remaining = keys.length;
                keys.forEach(function (key) {
                    var req = store.get(key);
                    req.onsuccess = function () {
                        var v = req.result;
                        if (v && v.data && typeof v.data.byteLength === "number") {
                            items.push({
                                key: key, type: v.type || "rom", fileSize: v.data.byteLength
                            });
                        }
                        remaining -= 1;
                        if (remaining === 0) finish(items);
                    };
                    req.onerror = function () {
                        remaining -= 1;
                        if (remaining === 0) finish(items);
                    };
                });
            };
        }, function () { post([]); });
    })();
    """

    private static func deleteScript(key: String) -> String {
        let encodedKey = (try? JSONEncoder().encode(key)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        return """
        (function () {
            var targetKey = \(encodedKey);
            \(openDatabaseJS)
            function done() {
                window.webkit.messageHandlers.cacheDeleted.postMessage(true);
            }
            openRomsDB(function (db) {
                var store = db.transaction("rom", "readwrite").objectStore("rom");
                store.delete(targetKey);
                var keysReq = store.get("?EJS_KEYS!");
                keysReq.onsuccess = function () {
                    var keys = keysReq.result || [];
                    var idx = keys.indexOf(targetKey);
                    if (idx !== -1) { keys.splice(idx, 1); store.put(keys, "?EJS_KEYS!"); }
                };
                var tx = store.transaction;
                tx.oncomplete = function () { db.close(); done(); };
                tx.onerror = function () { db.close(); done(); };
                tx.onabort = function () { db.close(); done(); };
            }, done);
        })();
        """
    }

    /// The written value matches EmulatorJS 4.2.3's own
    /// `storage.rom.put(gameUrl.split("/").pop(), { "content-length": ...,
    /// data: <ArrayBuffer> })` byte for byte, `data` stored as an
    /// ArrayBuffer (not a Uint8Array view: the hit path hands
    /// `result.data` straight to `gotGameData`, same as a fresh
    /// `xhr.response`), and the `?EJS_KEYS!` bookkeeping matches
    /// `addFileToDB`.
    private static func putScript(entryJSON: String) -> String {
        """
        (function () {
            var entry = \(entryJSON);
            \(openDatabaseJS)
            var key = entry.url.split("/").pop();
            console.log("[cachePut] start", key, "base64 length", entry.base64.length);
            function done(ok) {
                console.log("[cachePut] done", ok, key);
                window.webkit.messageHandlers.cachePut.postMessage(!!ok);
            }
            var bytes;
            try {
                var binary = atob(entry.base64);
                bytes = new Uint8Array(binary.length);
                for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
                console.log("[cachePut] decoded bytes", bytes.byteLength);
            } catch (e) {
                console.error("[cachePut] decode failed", e);
                done(false);
                return;
            }
            var value = { "content-length": entry.contentLength, data: bytes.buffer };
            if (entry.type) value.type = entry.type;
            openRomsDB(function (db) {
                var store = db.transaction("rom", "readwrite").objectStore("rom");
                store.put(value, key);
                var keysReq = store.get("?EJS_KEYS!");
                keysReq.onsuccess = function () {
                    var keys = keysReq.result || [];
                    if (keys.indexOf(key) === -1) { keys.push(key); store.put(keys, "?EJS_KEYS!"); }
                };
                var tx = store.transaction;
                tx.oncomplete = function () { db.close(); done(true); };
                tx.onerror = function () {
                    console.error("[cachePut] tx.onerror", tx.error);
                    db.close();
                    done(false);
                };
                tx.onabort = function () {
                    console.error("[cachePut] tx.onabort", tx.error);
                    db.close();
                    done(false);
                };
            }, function (err) {
                console.error("[cachePut] indexedDB.open failed", err);
                done(false);
            });
        })();
        """
    }
}

/// The invisible webview the bridge above drives, present in the view
/// hierarchy (rather than detached) since an unattached `WKWebView` is not
/// reliably guaranteed to run script or finish navigation on every iOS
/// version.
struct EmulatorCacheWebView: UIViewRepresentable {
    let url: URL
    @ObservedObject var bridge: EmulatorCacheBridge

    func makeCoordinator() -> Coordinator { Coordinator(bridge: bridge) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "cacheList")
        config.userContentController.add(context.coordinator, name: "cacheDeleted")
        config.userContentController.add(context.coordinator, name: "cachePut")
        config.userContentController.add(context.coordinator, name: "bridgeConsole")
        // Overrides console.* before any other script runs, so every
        // [cachePut]/[cacheList] line the list/delete/put scripts already
        // log also reaches native code, into BridgeConsoleLog, without
        // needing Safari's Web Inspector attached to see it.
        config.userContentController.addUserScript(
            WKUserScript(
                source: Self.consoleCaptureScript, injectionTime: .atDocumentStart, forMainFrameOnly: false
            )
        )
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        #if DEBUG
        // Reachable from Safari on the Mac this device is paired with:
        // Develop menu > device name > this app's hidden page. Needed to
        // actually see what's happening inside the cache bridge rather
        // than guess at it, the timed-out Data Saver attempts on
        // Dodonpachi II and Advance Wars 2 have no diagnosis yet.
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        #endif
        webView.load(URLRequest(url: url))
        bridge.attach(webView)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let bridge: EmulatorCacheBridge
        init(bridge: EmulatorCacheBridge) { self.bridge = bridge }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in bridge.handleReady() }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in bridge.handleLoadFailed() }
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
        ) {
            Task { @MainActor in bridge.handleLoadFailed() }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "cacheList":
                if let json = message.body as? String {
                    Task { @MainActor in bridge.handleList(json) }
                }
            case "cacheDeleted":
                Task { @MainActor in bridge.handleDeleted() }
            case "cachePut":
                let success = (message.body as? Bool) ?? false
                Task { @MainActor in bridge.handlePut(success) }
            case "bridgeConsole":
                if let line = message.body as? String {
                    BridgeConsoleLog.append(line)
                }
            default:
                break
            }
        }
    }

    /// Wraps `console.log`/`warn`/`error` rather than replacing them, so
    /// anything still visible in a real Web Inspector session keeps
    /// working exactly as before, this only adds a second destination.
    private static let consoleCaptureScript = """
        (function () {
            ["log", "warn", "error"].forEach(function (level) {
                var original = console[level];
                console[level] = function () {
                    original.apply(console, arguments);
                    try {
                        var parts = Array.prototype.slice.call(arguments).map(function (a) {
                            if (typeof a === "string") return a;
                            try { return JSON.stringify(a); } catch (e) { return String(a); }
                        });
                        window.webkit.messageHandlers.bridgeConsole.postMessage(
                            "[" + level + "] " + parts.join(" ")
                        );
                    } catch (e) {}
                };
            });
        })();
        """
}
