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

/// An info button that shows its explanation on hover almost immediately, and
/// stays open when clicked.
///
/// `.help()` can't be used for this: its tooltip delay is a system setting the
/// app can't shorten, and the tooltip can't be pinned open long enough to read
/// a couple of sentences. This shows a popover after a short hover, or
/// immediately on click — and a clicked popover stays put until dismissed, so
/// the pointer can leave without it vanishing mid-sentence.
struct InfoHint: View {
    let text: String
    var systemImage: String = "info.circle"
    /// Kept well under the system tooltip delay so it feels immediate, but not
    /// zero — otherwise it fires while the pointer is just passing over.
    var hoverDelay: Duration = .milliseconds(200)

    @State private var isPresented = false
    /// Opened by a click, so moving the pointer away shouldn't close it.
    @State private var isPinned = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        Image(systemName: systemImage)
            .contentShape(Rectangle())
            .onTapGesture {
                hoverTask?.cancel()
                if isPresented && isPinned {
                    dismiss()
                } else {
                    isPresented = true
                    isPinned = true
                }
            }
            .onHover { isHovering in
                hoverTask?.cancel()
                guard !isPinned else { return }

                if isHovering {
                    hoverTask = Task {
                        try? await Task.sleep(for: hoverDelay)
                        guard !Task.isCancelled else { return }
                        isPresented = true
                    }
                } else {
                    isPresented = false
                }
            }
            .onDisappear {
                hoverTask?.cancel()
            }
            .popover(
                isPresented: Binding(
                    get: { isPresented },
                    // Covers dismissal from outside, e.g. clicking elsewhere.
                    set: { if !$0 { dismiss() } else { isPresented = true } }
                ),
                arrowEdge: .bottom
            ) {
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 280, alignment: .leading)
                    .padding(12)
            }
            .accessibilityLabel("More information")
            .accessibilityHint(text)
    }

    private func dismiss() {
        isPresented = false
        isPinned = false
    }
}

struct SectionHeaderCard: View {
    let title: String
    let description: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.system(size: 30, weight: .semibold, design: .default))
            }

            Text(description)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.14), Color(nsColor: .windowBackgroundColor)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.accentColor.opacity(0.22), lineWidth: 1)
        )
        .glowCardStyle()
    }
}

struct GlowCardStyle: ViewModifier {
    var radius: CGFloat = 12
    var opacity: Double = 0.08

    func body(content: Content) -> some View {
        content
            .shadow(color: Color.accentColor.opacity(opacity), radius: radius, x: 0, y: 0)
            .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 3)
    }
}

extension View {
    func glowCardStyle(radius: CGFloat = 12, opacity: Double = 0.08) -> some View {
        modifier(GlowCardStyle(radius: radius, opacity: opacity))
    }
}

/// A prominent, celebratory success notification banner used to confirm that a
/// long-running action (YouTube rip, add music, consolidation, backup) finished.
struct SuccessBanner: View {
    let message: String
    var title: String = "Success"
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: Color.black.opacity(0.18), radius: 1, x: 0, y: 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white.opacity(0.96))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(6)
                        .background(Circle().fill(Color.white.opacity(0.18)))
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.16, green: 0.68, blue: 0.36),
                            Color(red: 0.10, green: 0.55, blue: 0.30)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.28), lineWidth: 1)
        )
        .shadow(color: Color.green.opacity(0.38), radius: 14, x: 0, y: 5)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(message)")
    }
}