//  PlatformAliases.swift
//
//  Milestone 0 foundation — a thin cross-platform type shim.
//
//  Shared code that will move into `ScribeCore` (and the markdown renderer,
//  image loader, and design tokens that follow it) needs to refer to one set
//  of names rather than branching on NSColor/UIColor at every call site.
//  macOS resolves these to AppKit; iOS / iPadOS resolves them to UIKit.
//
//  Groundwork only: existing macOS code is NOT yet migrated onto these
//  aliases — that happens when the renderer is ported (Milestone 2). Keeping
//  the shim here now lets the port be a mechanical find/replace later.

#if os(macOS)
import AppKit
public typealias PlatformColor = NSColor
public typealias PlatformFont = NSFont
public typealias PlatformImage = NSImage
#elseif os(iOS)
import UIKit
public typealias PlatformColor = UIColor
public typealias PlatformFont = UIFont
public typealias PlatformImage = UIImage
#endif
