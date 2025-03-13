import AppKit

let pasteboard = NSPasteboard.general
let items = [
    ("Test entry for relative time search 1", NSPasteboard.PasteboardType.string),
    ("Test entry for relative time search 2", NSPasteboard.PasteboardType.string),
    ("https://example.com/test", NSPasteboard.PasteboardType.URL)
]

for (content, type) in items {
    pasteboard.clearContents()
    pasteboard.setString(content, forType: type)
    Thread.sleep(forTimeInterval: 1) // Wait for clipboard manager to process
}
