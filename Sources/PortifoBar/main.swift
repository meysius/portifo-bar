import AppKit

// `--tail SYMBOLS` prints the feed to the terminal instead (see Tail).
let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--tail") {
    let list = arguments.dropFirst(flag + 1).first ?? "AAPL"
    Tail.run(list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() })
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// A menu bar item only: no Dock icon, no app menu.
app.setActivationPolicy(.accessory)
app.run()
