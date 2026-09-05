// EZLibrary — an open source toolkit for Serato DJ libraries.
// Copyright (C) 2026 Tawaun Lucas
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed WITHOUT ANY WARRANTY; see the GNU
// General Public License (LICENSE) for more details.

import SwiftUI
import AppKit

/// A side panel that the user can drag to resize, or collapse to a slim icon
/// strip to hand its width back to the neighboring content. Both the width and
/// the collapsed state are owned by the caller so they can be persisted.
struct CollapsibleSidePanel<Content: View>: View {
    let title: String
    let systemImage: String
    @Binding var isCollapsed: Bool
    @Binding var width: CGFloat
    var minWidth: CGFloat = 220
    var maxWidth: CGFloat = 560
    @ViewBuilder let content: () -> Content

    var body: some View {
        if isCollapsed {
            collapsedStrip
        } else {
            expandedPanel
        }
    }

    private var collapsedStrip: some View {
        VStack(spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isCollapsed = false }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Show \(title)")

            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isCollapsed = false }
            } label: {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Show \(title)")

            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .frame(width: 34)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .overlay(alignment: .trailing) { Divider() }
    }

    private var expandedPanel: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Label(title, systemImage: systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { isCollapsed = true }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .help("Hide \(title)")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)

                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: width)

            PanelResizeHandle(width: $width, minWidth: minWidth, maxWidth: maxWidth)
        }
    }
}

/// A thin, draggable divider that resizes an adjacent panel. Shared by every
/// resizable side panel so the cursor and drag math stay consistent.
struct PanelResizeHandle: View {
    @Binding var width: CGFloat
    var minWidth: CGFloat
    var maxWidth: CGFloat
    /// +1 when the panel sits to the left of the handle (drag right widens it),
    /// -1 when the panel sits to the right.
    var edgeSign: CGFloat = 1

    /// The width when the current drag started, so the translation applies to a
    /// fixed base instead of compounding every frame.
    @State private var widthAtDragStart: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 8)
            .overlay { Divider() }
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = widthAtDragStart ?? width
                        if widthAtDragStart == nil { widthAtDragStart = width }
                        width = min(max(base + edgeSign * value.translation.width, minWidth), maxWidth)
                    }
                    .onEnded { _ in widthAtDragStart = nil }
            )
    }
}
