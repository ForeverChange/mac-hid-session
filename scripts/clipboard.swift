// Normal-user helper: writes selected files or stdin text; never reads the old clipboard.
import AppKit
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
guard let mode = args.first else {
    fputs("Usage: clipboard --files PATH... | --text-stdin\n", stderr)
    exit(2)
}
if mode == "--files" && args.count > 1 && args.count <= 17 {
    let urls = args.dropFirst().map { URL(fileURLWithPath: $0).standardizedFileURL }
    guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { exit(3) }
    NSPasteboard.general.clearContents()
    guard NSPasteboard.general.writeObjects(urls.map { $0 as NSURL }) else { exit(4) }
    print("Prepared \(urls.count) file(s); nothing pasted or sent.")
} else if mode == "--text-stdin" && args.count == 1 {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard data.count <= 32768, let text = String(data: data, encoding: .utf8) else { exit(3) }
    NSPasteboard.general.clearContents()
    guard NSPasteboard.general.setString(text, forType: .string) else { exit(4) }
    print("Prepared text; nothing pasted or sent.")
} else { exit(2) }
