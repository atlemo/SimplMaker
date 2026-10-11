// Copyright © 2026 Atle Mo. All rights reserved.
import Testing

/// The suites that open a real window and drive it as the key window: its first responder, key events, the parameter
/// completer's key monitor. There is one key window and one completer for the whole test process, and these tests
/// wait (`Task.sleep`) while the main actor runs other tests, so two of them overlapping take the focus from each
/// other and fail at random. Suites nested here run one after the other.
@Suite(.serialized) enum KeyWindowTests {}
