import AppKit

let pasteboard = NSPasteboard.general
let items = [
    ("Testing DATABASE case sensitivity", NSPasteboard.PasteboardType.string),
    ("Another test with DataBase mixed case", NSPasteboard.PasteboardType.string)
]

for (content, type) in items {
    pasteboard.clearContents()
    pasteboard.setString(content, forType: type)
    Thread.sleep(forTimeInterval: 1) // Wait for clipboard manager to process
}
