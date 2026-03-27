# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ZenSSH (zpfssh) — a native macOS SSH terminal client built with SwiftUI + SwiftTerm. Features multi-tab/multi-pane terminal management, SFTP file transfer, command snippets, broadcast mode, and ZModem support.

## Build & Run

```bash
# Release build → .app bundle (code-signed, ad-hoc)
./build.sh

# Create distributable DMG
./make_dmg.sh

# SPM resolve (Xcode handles this automatically)
swift package resolve
```

Primary development is done in **Xcode** via `ZenSSH.xcodeproj`. The CLI `swift build` fails due to toolchain issues — always use Xcode or `xcodebuild` for compilation.

- **Minimum deployment:** macOS 14 (Package.swift), macOS 13 (Info.plist)
- **Swift tools version:** 6.0
- **No test suite** exists in the project

## Architecture

MVVM with `@MainActor` threading model. All UI state management is on the main actor; SSH/SFTP operations run in background `Task` contexts with `DispatchQueue.main.async` bridging.

### Layer Diagram

```
Views (SwiftUI)  →  ViewModels (@MainActor ObservableObject)  →  Models (value types)
                                                                      ↕
                                                               Services (SSH, SFTP, ZModem)
                                                                      ↕
                                                               SwiftTerm / Citadel / NIO
```

### Key Architectural Decisions

- **All tabs render simultaneously** with opacity 0/1 toggle — SSH processes stay alive across tab switches
- **PaneLayout is a recursive enum** (`.leaf` / `.split`) enabling arbitrary nested split trees (like tmux)
- **AppKit drop overlay** (`PaneDropNSView`) handles drag-and-drop over terminal views — SwiftUI's `.onDrop` is unreliable when an AppKit NSView sits underneath
- **Drag payload format:** `"TAB:<uuid>"` for tab drags, `"PANE:<uuid>"` for pane drags, using custom UTTypes `com.zpfssh.tab-id` and `com.zpfssh.pane-id`
- **Passwords stored in macOS Keychain** via `CredentialService`, never in config files

### Core Type Relationships

- **`SessionManager`** owns `[SessionTab]`, manages cross-tab split and broadcast
- **`SessionTab`** owns a `PaneLayout` tree + `[UUID: PaneSession]` map
- **`PaneLayout`** recursive enum: `.leaf(id)` or `.split(id, direction, ratio, first, second)`
- **`PaneSession`** holds connection state for one terminal pane
- **`Server`** defines SSH connection params (host, port, auth type, jump host)
- **`ServerStore`** persists servers to UserDefaults, passwords to Keychain

### SSH Connection Flow

`TerminalPaneView` (NSViewRepresentable) → `ZModemTerminalView` (SwiftTerm subclass) → launches `/usr/bin/ssh` via `LocalProcessTerminalView.startProcess()`. Auth is handled by `SSHAskPassService` which sets `SSH_ASKPASS` env vars.

## Dependencies

- **SwiftTerm** (v1.12.0) — Terminal emulation (VT100/xterm-256color)
- **Citadel** (v0.12.0) — Pure-Swift SSH/SFTP (powers SFTPService)
- Transitive: swift-nio, swift-crypto, BigInt, swift-argument-parser

## PRD Reference

`PRD.md` contains the full product spec (in Chinese). Key sections:
- §3.3 — Terminal workspace free arrangement (drag-split, pane composition)
- §3.4 — SFTP file transfer
- §3.5 — Command snippets with `{{placeholder}}` templating
- §3.6 — Broadcast mode
