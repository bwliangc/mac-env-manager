import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("usage: make_icns.swift ICONSET_DIR OUTPUT.icns\n", stderr)
    exit(2)
}

let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2])

let chunks: [(String, String)] = [
    ("icp4", "icon_16x16.png"),
    ("icp5", "icon_32x32.png"),
    ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"),
    ("ic11", "icon_16x16@2x.png"),
    ("ic12", "icon_32x32@2x.png"),
    ("ic13", "icon_128x128@2x.png"),
    ("ic14", "icon_256x256@2x.png")
]

func fourCC(_ value: String) -> Data {
    Data(value.utf8)
}

func bigEndian(_ value: UInt32) -> Data {
    var encoded = value.bigEndian
    return Data(bytes: &encoded, count: MemoryLayout<UInt32>.size)
}

var body = Data()
for (type, filename) in chunks {
    let data = try Data(contentsOf: iconset.appendingPathComponent(filename))
    body.append(fourCC(type))
    body.append(bigEndian(UInt32(data.count + 8)))
    body.append(data)
}

var result = Data("icns".utf8)
result.append(bigEndian(UInt32(body.count + 8)))
result.append(body)
try result.write(to: output, options: .atomic)
