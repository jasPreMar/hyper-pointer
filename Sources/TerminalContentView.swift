import AppKit
import SwiftUI
import Combine

// MARK: - Stream Status

enum StreamStatus: Equatable {
    case waiting
    case streaming
    case done
    case error(String)
}

// MARK: - Claude Process Manager

class ClaudeProcessManager: ObservableObject {
    @Published var outputText = ""
    @Published var status: StreamStatus = .waiting
    var onComplete: ((String) -> Void)?

    private var process: Process?
    private var buffer = Data()
    private let queue = DispatchQueue(label: "claude-stream", qos: .userInitiated)

    func start(message: String) {
        guard let claudePath = resolveClaudePath() else {
            status = .error("Could not find 'claude' binary")
            return
        }

        let process = Process()
        self.process = process

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c",
            "\(claudePath) -p \"$HP_MESSAGE\" --output-format stream-json --verbose --dangerously-skip-permissions 2>&1"
        ]
        process.standardInput = FileHandle.nullDevice

        // Build clean environment
        var env = ProcessInfo.processInfo.environment
        let claudeKeys = env.keys.filter { $0.uppercased().contains("CLAUDE") }
        for key in claudeKeys { env.removeValue(forKey: key) }
        let extraPaths = ["/usr/local/bin", "/opt/homebrew/bin",
                          NSHomeDirectory() + "/.local/bin"]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
        env["HP_MESSAGE"] = message
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // Read stdout on a background thread (more reliable than readabilityHandler)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let handle = stdout.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty { break } // EOF
                self?.queue.async { self?.handleData(data) }
            }
        }

        // Read stderr on a background thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let handle = stderr.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                if let text = String(data: data, encoding: .utf8) {
                    DispatchQueue.main.async {
                        self?.outputText += "[STDERR] \(text)\n"
                        if case .waiting = self?.status { self?.status = .streaming }
                    }
                }
            }
        }

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if case .error = self.status { return }
                if proc.terminationStatus == 0 {
                    self.status = .done
                    self.onComplete?(self.accumulated)
                } else {
                    self.status = .error("Exit code \(proc.terminationStatus)")
                }
            }
        }

        do {
            try process.run()
        } catch {
            status = .error("Failed to launch: \(error.localizedDescription)")
            return
        }
    }

    private func handleData(_ data: Data) {
        buffer.append(data)

        // Split buffer on newlines, process complete lines
        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<newlineIndex]
            buffer = Data(buffer[buffer.index(after: newlineIndex)...])

            guard let line = String(data: lineData, encoding: .utf8),
                  !line.trimmingCharacters(in: .whitespaces).isEmpty else {
                continue
            }

            if let text = extractText(from: line) {
                DispatchQueue.main.async {
                    if case .waiting = self.status { self.status = .streaming }
                    self.outputText = text
                }
            }
        }
    }

    private var accumulated = ""

    private func extractText(from jsonLine: String) -> String? {
        guard let data = jsonLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return nil
        }

        // Final result — complete text, use as source of truth
        if type == "result",
           let result = json["result"] as? String {
            accumulated = result
            return accumulated
        }

        // content_block_delta — streaming text tokens
        if type == "content_block_delta",
           let delta = json["delta"] as? [String: Any],
           let deltaType = delta["type"] as? String,
           deltaType == "text_delta",
           let text = delta["text"] as? String {
            accumulated += text
            return accumulated
        }

        // Verbose assistant message with full content array
        if type == "assistant",
           let message = json["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]] {
            for block in content {
                if block["type"] as? String == "text",
                   let text = block["text"] as? String {
                    accumulated = text
                    return accumulated
                }
            }
        }

        return nil
    }

    private func resolveClaudePath() -> String? {
        let candidates = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            NSHomeDirectory() + "/.local/bin/claude"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Fallback: use zsh to resolve
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/bin/zsh")
        which.arguments = ["-lc", "which claude"]
        let pipe = Pipe()
        which.standardOutput = pipe
        try? which.run()
        which.waitUntilExit()
        let result = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let path = result, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    deinit {
        process?.terminate()
    }
}

// MARK: - Panel Content View (switches between search and chat)

struct PanelContentView: View {
    @ObservedObject var viewModel: SearchViewModel

    var body: some View {
        if viewModel.isChatMode {
            ChatView(viewModel: viewModel)
        } else {
            SearchView(viewModel: viewModel)
        }
    }
}

// MARK: - Chat View (output + input in the floating panel)

struct ChatView: View {
    @ObservedObject var viewModel: SearchViewModel
    @State private var textHeight: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            // Draggable header with close button and status
            HStack(spacing: 6) {
                Button(action: { viewModel.onClose?() }) {
                    Circle()
                        .fill(Color(nsColor: .systemRed))
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.plain)

                if let manager = viewModel.claudeManager {
                    statusIndicator(for: manager)
                    statusLabel(for: manager)
                }

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(DragArea())

            // Scrollable output
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(viewModel.chatHistory.enumerated()), id: \.offset) { _, entry in
                            if entry.role == "user" {
                                Text("> \(entry.text)")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.secondary)
                            } else {
                                Text(entry.text)
                                    .font(.system(size: 13))
                                    .textSelection(.enabled)
                            }
                        }

                        if let manager = viewModel.claudeManager,
                           !manager.outputText.isEmpty {
                            Text(manager.outputText)
                                .font(.system(size: 13))
                                .textSelection(.enabled)
                                .id("bottom")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: viewModel.claudeManager?.outputText) { _, _ in
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }

            // Input field
            HStack(alignment: .top, spacing: 4) {
                Text(">")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.top, 1)

                FocusedTextField(text: $viewModel.query, textHeight: $textHeight, onSubmit: {
                    viewModel.submitMessage()
                })
                .frame(height: textHeight)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .frame(width: 360, height: 320)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 2, x: 0, y: 1)
        .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
        )
        .padding(16)
    }

    @ViewBuilder
    private func statusIndicator(for manager: ClaudeProcessManager) -> some View {
        switch manager.status {
        case .waiting:
            ProgressView().controlSize(.small)
        case .streaming:
            Circle().fill(.green).frame(width: 6, height: 6)
        case .done:
            Circle().fill(.blue).frame(width: 6, height: 6)
        case .error:
            Circle().fill(.red).frame(width: 6, height: 6)
        }
    }

    @ViewBuilder
    private func statusLabel(for manager: ClaudeProcessManager) -> some View {
        switch manager.status {
        case .waiting:
            Text("Thinking...").font(.caption2).foregroundColor(.secondary)
        case .streaming:
            Text("Streaming...").font(.caption2).foregroundColor(.green)
        case .done:
            EmptyView()
        case .error(let msg):
            Text(msg).font(.caption2).foregroundColor(.red).lineLimit(1)
        }
    }
}

// MARK: - Drag Area (makes the header draggable)

struct DragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = DragView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

class DragView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
