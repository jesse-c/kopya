import AppKit

let pasteboard = NSPasteboard.general
pasteboard.clearContents()
let url = "https://github.com/jesse-c/kopya"
pasteboard.setString(url, forType: .URL)
