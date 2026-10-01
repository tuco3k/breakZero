import Foundation

/// Raw DEFLATE (RFC 1951) decoder, for reading Instagram's data export zip on any platform (the
/// package must build on Linux, so no Compression framework). Small and strict: every read is
/// bounds-checked and the output is capped, so a hostile archive can only fail, never hang or
/// grow without limit. Algorithm after zlib's `puff.c`.
public enum Inflate {
    public enum Failure: Error, Equatable {
        case corrupt
        case tooLarge
    }

    public static func inflate(_ input: [UInt8], maxOutput: Int) throws -> [UInt8] {
        var s = State(input: input, maxOutput: maxOutput)
        var last = false
        while !last {
            last = try s.bits(1) == 1
            switch try s.bits(2) {
            case 0: try s.stored()
            case 1: try s.codes(Self.fixed.lit, Self.fixed.dist)
            case 2:
                let (lit, dist) = try s.dynamicTables()
                try s.codes(lit, dist)
            default: throw Failure.corrupt
            }
        }
        return s.out
    }

    struct Huffman {
        var count = [Int](repeating: 0, count: 16)
        var symbol: [Int]

        init(lengths: [Int]) throws {
            symbol = [Int](repeating: 0, count: lengths.count)
            for l in lengths { count[l] += 1 }
            if count[0] == lengths.count { return }   // no codes: decoding fails if ever used
            var left = 1
            for len in 1..<16 {
                left <<= 1
                left -= count[len]
                if left < 0 { throw Failure.corrupt }   // over-subscribed
            }
            var offs = [Int](repeating: 0, count: 16)
            for len in 1..<15 { offs[len + 1] = offs[len] + count[len] }
            for (sym, l) in lengths.enumerated() where l != 0 {
                symbol[offs[l]] = sym
                offs[l] += 1
            }
        }
    }

    static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537,
                           2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    static let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    static let fixed: (lit: Huffman, dist: Huffman) = {
        var l = [Int](repeating: 8, count: 288)
        for i in 144..<256 { l[i] = 9 }
        for i in 256..<280 { l[i] = 7 }
        // Valid by construction.
        return (try! Huffman(lengths: l), try! Huffman(lengths: [Int](repeating: 5, count: 30)))
    }()

    struct State {
        let input: [UInt8]
        let maxOutput: Int
        var pos = 0
        var bitBuf = 0
        var bitCount = 0
        var out: [UInt8] = []

        init(input: [UInt8], maxOutput: Int) {
            self.input = input
            self.maxOutput = maxOutput
        }

        mutating func bits(_ n: Int) throws -> Int {
            while bitCount < n {
                guard pos < input.count else { throw Failure.corrupt }
                bitBuf |= Int(input[pos]) << bitCount
                pos += 1
                bitCount += 8
            }
            let v = bitBuf & ((1 << n) - 1)
            bitBuf >>= n
            bitCount -= n
            return v
        }

        mutating func emit(_ b: UInt8) throws {
            guard out.count < maxOutput else { throw Failure.tooLarge }
            out.append(b)
        }

        mutating func stored() throws {
            bitBuf = 0   // fewer than 8 bits are ever buffered: drop to the byte boundary
            bitCount = 0
            guard pos + 4 <= input.count else { throw Failure.corrupt }
            let len = Int(input[pos]) | Int(input[pos + 1]) << 8
            let nlen = Int(input[pos + 2]) | Int(input[pos + 3]) << 8
            pos += 4
            guard len == ~nlen & 0xFFFF, pos + len <= input.count else { throw Failure.corrupt }
            guard out.count + len <= maxOutput else { throw Failure.tooLarge }
            out.append(contentsOf: input[pos..<(pos + len)])
            pos += len
        }

        mutating func decode(_ h: Huffman) throws -> Int {
            var code = 0, first = 0, index = 0
            for len in 1..<16 {
                code |= try bits(1)
                let count = h.count[len]
                if code - count < first { return h.symbol[index + (code - first)] }
                index += count
                first += count
                first <<= 1
                code <<= 1
            }
            throw Failure.corrupt
        }

        mutating func codes(_ lit: Huffman, _ dist: Huffman) throws {
            while true {
                let sym = try decode(lit)
                if sym < 256 { try emit(UInt8(sym)); continue }
                if sym == 256 { return }
                let li = sym - 257
                guard li < Inflate.lengthBase.count else { throw Failure.corrupt }
                let len = Inflate.lengthBase[li] + (try bits(Inflate.lengthExtra[li]))
                let di = try decode(dist)
                guard di < Inflate.distBase.count else { throw Failure.corrupt }
                let d = Inflate.distBase[di] + (try bits(Inflate.distExtra[di]))
                guard d <= out.count else { throw Failure.corrupt }
                guard out.count + len <= maxOutput else { throw Failure.tooLarge }
                let start = out.count - d
                for i in 0..<len { out.append(out[start + i]) }   // may overlap: byte by byte
            }
        }

        mutating func dynamicTables() throws -> (Huffman, Huffman) {
            let nlen = try bits(5) + 257, ndist = try bits(5) + 1, ncode = try bits(4) + 4
            guard nlen <= 286, ndist <= 30 else { throw Failure.corrupt }
            var lengths = [Int](repeating: 0, count: 19)
            for i in 0..<ncode { lengths[Inflate.codeLengthOrder[i]] = try bits(3) }
            let lencode = try Huffman(lengths: lengths)
            var all: [Int] = []
            while all.count < nlen + ndist {
                let sym = try decode(lencode)
                switch sym {
                case 0..<16: all.append(sym)
                case 16:
                    guard let prev = all.last else { throw Failure.corrupt }
                    all += [Int](repeating: prev, count: 3 + (try bits(2)))
                case 17: all += [Int](repeating: 0, count: 3 + (try bits(3)))
                default: all += [Int](repeating: 0, count: 11 + (try bits(7)))
                }
            }
            guard all.count == nlen + ndist, all[256] != 0 else { throw Failure.corrupt }
            return (try Huffman(lengths: Array(all[0..<nlen])), try Huffman(lengths: Array(all[nlen...])))
        }
    }
}
