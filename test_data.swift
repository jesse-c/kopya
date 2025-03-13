import AppKit

let pasteboard = NSPasteboard.general
let items = [
    ("This is a test database with a URL: https://example.com", NSPasteboard.PasteboardType.string),
    ("https://github.com/jesse-c/kopya/database", NSPasteboard.PasteboardType.URL),
    ("Another database entry", NSPasteboard.PasteboardType.string)
]

for (content, type) in items {
    pasteboard.clearContents()
    pasteboard.setString(content, forType: type)
    Thread.sleep(forTimeInterval: 1) // Wait for clipboard manager to process
}
