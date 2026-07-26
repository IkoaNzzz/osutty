import AppKit
import SwiftUI

enum SidecarGitDiffState {
    case loading
    case content(String)
    case failure(String)
}

struct SidecarGitDiffPopover: View {
    let path: String
    let isStaged: Bool
    let state: SidecarGitDiffState

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(path)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.head)

                    Text(isStaged ? "Staged changes" : "Working tree changes")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                SidecarToolbarButton(
                    systemImage: "xmark",
                    help: "Close"
                ) {
                    dismiss()
                }
                .accessibilityLabel("Close Diff Preview")
            }
            .padding(.horizontal, 12)
            .frame(height: 48)

            Divider()

            Group {
                switch state {
                case .loading:
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading diff…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .content(let diff):
                    SidecarGitDiffTextView(diff: diff)

                case .failure(let message):
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(5)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(width: 640, height: 420)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidecar-git-diff-popover")
    }
}

private struct SidecarGitDiffTextView: NSViewRepresentable {
    let diff: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .init(width: 12, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.minSize = .zero
        textView.maxSize = .init(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.containerSize = .init(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.setAccessibilityIdentifier("sidecar-git-diff-text")
        scrollView.documentView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.render(diff, in: textView)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.cancel()
    }

    final class Coordinator {
        private static let queue = DispatchQueue(
            label: "io.github.ikoanzzz.osutty.sidecar.diff-format",
            qos: .userInitiated
        )

        private var lastDiff: String?
        private var generation = UUID()

        func render(_ diff: String, in textView: NSTextView) {
            guard lastDiff != diff else { return }
            lastDiff = diff
            let currentGeneration = UUID()
            generation = currentGeneration

            Self.queue.async { [weak self, weak textView] in
                let attributed = SidecarGitDiffFormatter.attributedString(diff)
                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let self,
                          generation == currentGeneration,
                          let textView else {
                        return
                    }
                    textView.textStorage?.setAttributedString(attributed)
                }
            }
        }

        func cancel() {
            generation = UUID()
            lastDiff = nil
        }
    }
}

enum SidecarGitDiffFormatter {
    static func attributedString(_ diff: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 1

        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line) + "\n"
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle,
            ]

            switch text {
            case _ where text.hasPrefix("diff --git "):
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
                attributes[.foregroundColor] = NSColor.secondaryLabelColor

            case _ where text.hasPrefix("@@"):
                attributes[.foregroundColor] = NSColor.systemBlue
                attributes[.backgroundColor] = NSColor.systemBlue.withAlphaComponent(0.08)

            case _ where text.hasPrefix("+") && !text.hasPrefix("+++"):
                attributes[.foregroundColor] = NSColor.systemGreen
                attributes[.backgroundColor] = NSColor.systemGreen.withAlphaComponent(0.08)

            case _ where text.hasPrefix("-") && !text.hasPrefix("---"):
                attributes[.foregroundColor] = NSColor.systemRed
                attributes[.backgroundColor] = NSColor.systemRed.withAlphaComponent(0.08)

            case _ where text.hasPrefix("index ")
                || text.hasPrefix("--- ")
                || text.hasPrefix("+++ "):
                attributes[.foregroundColor] = NSColor.secondaryLabelColor

            default:
                break
            }

            result.append(NSAttributedString(string: text, attributes: attributes))
        }

        return result
    }
}
