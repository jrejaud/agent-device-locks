// type-to-pid — deliver keystrokes to ONE process (CGEventPostToPid) instead of to
// whatever has focus. Any app, not just iTerm: the target need not be frontmost, so
// the user keeps their focus and keys can never land in another app. Cocoa apps route
// the events to their key window (including non-activating panels).
//
//   type-to-pid <pid> text <string>         type a string
//   type-to-pid <pid> key <name> [mods]     return|escape|tab|delete|space|up|down|left|right,
//                                           a-z, 0-9; mods = cmd,shift,alt,ctrl
//
// Find the pid with lsappinfo / pgrep / `peekaboo list apps`.
import Foundation
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 4, let pid = pid_t(args[1]) else {
    FileHandle.standardError.write("usage: type-to-pid <pid> text <string> | key <name> [mods]\n".data(using: .utf8)!)
    exit(2)
}
let source = CGEventSource(stateID: .hidSystemState)
func post(_ code: CGKeyCode, _ flags: CGEventFlags = [], unicode: [UniChar]? = nil) {
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)!
        e.flags = flags
        if let unicode { e.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: unicode) }
        e.postToPid(pid)
        usleep(8000)
    }
}
switch args[2] {
case "text":
    for ch in args[3].utf16 { post(0, unicode: [ch]) }
case "key":
    let codes: [String: CGKeyCode] = ["return": 36, "escape": 53, "tab": 48, "delete": 51, "space": 49,
                                      "left": 123, "right": 124, "down": 125, "up": 126,
                                      "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
                                      "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
                                      "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31,
                                      "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46]
    guard let code = codes[args[3]] else { print("unknown key \(args[3])"); exit(2) }
    var flags: CGEventFlags = []
    for m in (args.count > 4 ? args[4] : "").split(separator: ",") {
        switch m { case "cmd": flags.insert(.maskCommand); case "shift": flags.insert(.maskShift)
                   case "alt": flags.insert(.maskAlternate); case "ctrl": flags.insert(.maskControl); default: break }
    }
    // Text fields interpret a key by its characters, so named keys carry them too.
    let characters: [String: UniChar] = ["return": 13, "escape": 27, "tab": 9, "delete": 127, "space": 32]
    // A real keyboard sends "T" for ⇧T, and iTerm matches key bindings by that
    // character: a lowercase one with ⇧ trips its "match by physical key?" modal.
    let name = flags.contains(.maskShift) ? args[3].uppercased() : args[3]
    let letter = args[3].count == 1 ? name.utf16.first : nil
    post(code, flags, unicode: (characters[args[3]] ?? letter).map { [$0] })
default:
    exit(2)
}
