// A bounds-checked element lookup.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
