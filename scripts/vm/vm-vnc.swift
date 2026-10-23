// A small command-line client for the VNC server that tart starts with
// `tart run --no-graphics --vnc-experimental`. It reads the VM's framebuffer and
// sends mouse and keyboard input from the host, so nothing runs in the guest and
// no window opens on the host. The scripts in scripts/vm compile and call it.
//
// Usage:
//   vm-vnc <vnc-url> size                    (prints the framebuffer size in pixels)
//   vm-vnc <vnc-url> screenshot <out.png>
//   vm-vnc <vnc-url> click <x> <y>          (framebuffer pixels)
//   vm-vnc <vnc-url> type <text>
//   vm-vnc <vnc-url> key <combo>            (for example: return, escape, tab, cmd+q, cmd+comma)
//
// Speaks RFB 3.8 with VNC password authentication and raw encoding only.

import CommonCrypto
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct VNCError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

final class Connection {
    private let fd: Int32

    init(host: String, port: UInt16) throws {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let info = result else {
            throw VNCError("can't resolve \(host)")
        }
        defer { freeaddrinfo(result) }
        fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd >= 0 else { throw VNCError("socket() failed") }
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else {
            throw VNCError("can't connect to \(host):\(port)")
        }
    }

    deinit { close(fd) }

    func read(_ count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + offset, count - offset) }
            guard n > 0 else { throw VNCError("connection closed or timed out while reading") }
            offset += n
        }
        return buffer
    }

    func u8() throws -> UInt8 { try read(1)[0] }
    func u16() throws -> UInt16 { let b = try read(2); return UInt16(b[0]) << 8 | UInt16(b[1]) }
    func u32() throws -> UInt32 {
        let b = try read(4)
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    func write(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            guard n > 0 else { throw VNCError("write failed") }
            offset += n
        }
    }
}

func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }
func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }

/// VNC authentication encrypts the challenge with DES, using the password with each byte's bits reversed.
func vncAuthResponse(challenge: [UInt8], password: String) throws -> [UInt8] {
    var key = [UInt8](repeating: 0, count: 8)
    for (i, byte) in Array(password.utf8.prefix(8)).enumerated() {
        var reversed: UInt8 = 0
        for bit in 0..<8 where byte & (1 << bit) != 0 { reversed |= 1 << (7 - bit) }
        key[i] = reversed
    }
    var out = [UInt8](repeating: 0, count: 16)
    var moved = 0
    let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionECBMode),
                         key, 8, nil, challenge, 16, &out, 16, &moved)
    guard status == kCCSuccess, moved == 16 else { throw VNCError("DES failed: \(status)") }
    return out
}

final class Session {
    let conn: Connection
    var width = 0
    var height = 0

    init(url: URL) throws {
        guard let host = url.host, let port = url.port else { throw VNCError("bad VNC URL: \(url)") }
        conn = try Connection(host: host, port: UInt16(port))

        let version = String(decoding: try conn.read(12), as: UTF8.self)
        guard version.hasPrefix("RFB ") else { throw VNCError("not a VNC server: \(version)") }
        try conn.write(Array("RFB 003.008\n".utf8))

        let typeCount = Int(try conn.u8())
        if typeCount == 0 {
            let reason = String(decoding: try conn.read(Int(try conn.u32())), as: UTF8.self)
            throw VNCError("server refused the connection: \(reason)")
        }
        let types = try conn.read(typeCount)
        if types.contains(2) {
            try conn.write([2])
            let challenge = try conn.read(16)
            let password = url.password?.removingPercentEncoding ?? ""
            try conn.write(try vncAuthResponse(challenge: challenge, password: password))
        } else if types.contains(1) {
            try conn.write([1])
        } else {
            throw VNCError("no supported security type in \(types)")
        }
        if try conn.u32() != 0 {
            throw VNCError("VNC authentication failed; is the password in the URL current?")
        }

        try conn.write([1])  // ClientInit, shared session
        width = Int(try conn.u16())
        height = Int(try conn.u16())
        _ = try conn.read(16)  // server pixel format
        _ = try conn.read(Int(try conn.u32()))  // desktop name

        // 32 bits per pixel, little-endian, 8 bits per channel: bytes arrive as B, G, R, unused.
        let pixelFormat: [UInt8] = [32, 24, 0, 1] + be16(255) + be16(255) + be16(255) + [16, 8, 0, 0, 0, 0]
        try conn.write([0, 0, 0, 0] + pixelFormat)
        // SetEncodings: raw, plus the DesktopSize and ExtendedDesktopSize pseudo-encodings.
        // The Virtualization framework's server drops clients that don't accept a size message.
        try conn.write([2, 0] + be16(3) + be32(0) + be32(UInt32(bitPattern: -223)) + be32(UInt32(bitPattern: -308)))
    }

    func screenshot(to path: String) throws {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var covered = 0
        var resized = false
        let deadline = Date().addingTimeInterval(20)
        try requestUpdate()
        while covered < width * height {
            guard Date() < deadline else { throw VNCError("timed out waiting for the framebuffer") }
            let type = try conn.u8()
            switch type {
            case 0:  // FramebufferUpdate
                _ = try conn.u8()
                let rects = Int(try conn.u16())
                for _ in 0..<rects {
                    let x = Int(try conn.u16()), y = Int(try conn.u16())
                    let w = Int(try conn.u16()), h = Int(try conn.u16())
                    let encoding = Int32(bitPattern: try conn.u32())
                    if encoding == -223 || encoding == -308 {
                        // The screen size changed. Start over at the new size.
                        if encoding == -308 {
                            let screens = Int(try conn.u8())
                            _ = try conn.read(3 + screens * 16)
                        }
                        width = w
                        height = h
                        pixels = [UInt8](repeating: 0, count: width * height * 4)
                        covered = 0
                        resized = true
                        continue
                    }
                    guard encoding == 0 else { throw VNCError("unexpected encoding \(encoding)") }
                    let data = try conn.read(w * h * 4)
                    for row in 0..<h where y + row < height {
                        let dst = ((y + row) * width + x) * 4
                        let src = row * w * 4
                        let count = min(w, width - x) * 4
                        pixels.replaceSubrange(dst..<(dst + count), with: data[src..<(src + count)])
                    }
                    covered += w * h
                }
                if resized || covered < width * height {
                    resized = false
                    try requestUpdate()
                }
            case 1:  // SetColourMapEntries
                _ = try conn.read(3)
                _ = try conn.read(Int(try conn.u16()) * 6)
            case 2:  // Bell
                break
            case 3:  // ServerCutText
                _ = try conn.read(3)
                _ = try conn.read(Int(try conn.u32()))
            default:
                throw VNCError("unexpected server message \(type)")
            }
        }
        try writePNG(pixels: pixels, to: path)
    }

    private func requestUpdate() throws {
        try conn.write([3, 0] + be16(0) + be16(0) + be16(UInt16(width)) + be16(UInt16(height)))
    }

    private func writePNG(pixels: [UInt8], to path: String) throws {
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil)
        else { throw VNCError("can't create the PNG") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw VNCError("can't write \(path)") }
    }

    func pointer(x: Int, y: Int, buttons: UInt8) throws {
        try conn.write([5, buttons] + be16(UInt16(x)) + be16(UInt16(y)))
    }

    func click(x: Int, y: Int) throws {
        try pointer(x: x, y: y, buttons: 0)
        usleep(100_000)
        try pointer(x: x, y: y, buttons: 1)
        usleep(80_000)
        try pointer(x: x, y: y, buttons: 0)
        usleep(100_000)
    }

    func key(_ keysym: UInt32, down: Bool) throws {
        try conn.write([4, down ? 1 : 0, 0, 0] + be32(keysym))
    }

    func press(_ keysyms: [UInt32]) throws {
        for k in keysyms { try key(k, down: true); usleep(30_000) }
        for k in keysyms.reversed() { try key(k, down: false); usleep(30_000) }
    }
}

let namedKeys: [String: UInt32] = [
    "return": 0xff0d, "enter": 0xff0d, "tab": 0xff09, "escape": 0xff1b, "esc": 0xff1b,
    "backspace": 0xff08, "delete": 0xffff, "space": 0x20, "comma": 0x2c, "period": 0x2e,
    "left": 0xff51, "up": 0xff52, "right": 0xff53, "down": 0xff54,
    "shift": 0xffe1, "ctrl": 0xffe3, "control": 0xffe3, "alt": 0xffe9, "option": 0xffe9,
    "cmd": 0xffe7, "command": 0xffe7,
]

func keysyms(forCombo combo: String) throws -> [UInt32] {
    try combo.lowercased().split(separator: "+").map { part in
        let name = String(part)
        if let k = namedKeys[name] { return k }
        if name.unicodeScalars.count == 1, let scalar = name.unicodeScalars.first, scalar.value < 0x100 {
            return scalar.value
        }
        throw VNCError("unknown key: \(name)")
    }
}

func run() throws {
    let args = CommandLine.arguments
    guard args.count >= 3, let url = URL(string: args[1]) else {
        throw VNCError("usage: vm-vnc <vnc-url> screenshot <out.png> | click <x> <y> | type <text> | key <combo>")
    }
    let session = try Session(url: url)
    switch (args[2], args.count) {
    case ("size", 3):
        print("\(session.width)x\(session.height)")
    case ("screenshot", 4):
        try session.screenshot(to: args[3])
    case ("click", 5):
        guard let x = Int(args[3]), let y = Int(args[4]) else { throw VNCError("click needs integer x and y") }
        try session.click(x: x, y: y)
    case ("type", 4):
        for scalar in args[3].unicodeScalars {
            let upper = CharacterSet.uppercaseLetters.contains(scalar)
            try session.press(upper ? [0xffe1, scalar.value] : [scalar.value])
        }
    case ("key", 4):
        try session.press(try keysyms(forCombo: args[3]))
    default:
        throw VNCError("unknown command or wrong number of arguments: \(args.dropFirst(2).joined(separator: " "))")
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("vm-vnc: \(error)\n".utf8))
    exit(1)
}
