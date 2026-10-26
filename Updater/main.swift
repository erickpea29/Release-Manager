import Foundation

// The updater service: replaces Relvora with a checked update (ADR 0017). It runs outside the app's sandbox, because a
// sandboxed app can't replace itself; only its own app can connect to it.
let delegate = UpdaterListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
