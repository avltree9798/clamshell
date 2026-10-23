// SPDX-License-Identifier: GPL-3.0-or-later

extension UInt32 {
    /// Rotate right by `n` bits (mod 32).
    @inline(__always) func rotatedRight(_ n: UInt32) -> UInt32 {
        let s = n & 31
        return s == 0 ? self : (self >> s) | (self << (32 - s))
    }

    /// Sign-extends the low `bits` bits.
    @inline(__always) func signExtended(bits: UInt32) -> UInt32 {
        let shift = 32 - bits
        return UInt32(bitPattern: Int32(bitPattern: self << shift) >> Int32(shift))
    }
}
