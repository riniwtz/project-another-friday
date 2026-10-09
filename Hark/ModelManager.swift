import Foundation
import Combine
import AppKit

struct LocalModel: Identifiable, Hashable {
    let id: String                   // Canonical local path/group ID
    let name: String
    let format: String
    let sizeBytes: Int64
    let location: String
    let source: String
}

@MainActor
final class ModelManager: ObservableObject {
    @Published private(set) var models: [LocalModel] = []
    @Published private(set) var isScanning = false
    @Published var additionalFolders: [String] {
        didSet { UserDefaults.standard.set(additionalFolders, forKey: "hark.modelFolders") }
    }

    init() {
        additionalFolders = UserDefaults.standard.stringArray(forKey: "hark.modelFolders") ?? []
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose a folder containing downloaded local AI model files."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = url.standardizedFileURL.path
            if !additionalFolders.contains(path) { additionalFolders.append(path) }
        }
        refresh()
    }

    func removeFolder(_ path: String) {
        additionalFolders.removeAll { $0 == path }
        refresh()
    }

    func reveal(_ model: LocalModel) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.location)])
    }

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        let extra = additionalFolders
        Task {
            let found = await Task.detached(priority: .utility) {
                ModelDiscovery.scan(extraFolders: extra)
            }.value
            models = found
            isScanning = false
        }
    }

    func installed(_ name: String) -> Bool {
        let key = name.lowercased().replacingOccurrences(of: "-", with: "")
        return models.contains { model in
            model.name.lowercased().replacingOccurrences(of: "-", with: "").contains(key)
        }
    }
}

/// Discover actual disk files. We never invent "downloaded" entries: the two AI backends
/// appear separately as integration targets until checkpoint files are found.
enum ModelDiscovery {
    static func scan(extraFolders: [String]) -> [LocalModel] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaults: [(String, String)] = [
            ("Library/Application Support/Hark/Models", "Hark"),
            ("Library/Application Support/AmbientLens/Models", "Legacy Hark"),
            (".cache/huggingface/hub", "Hugging Face"),
            ("Library/Caches/huggingface/hub", "Hugging Face"),
            (".cache/lm-studio/models", "LM Studio"),
            (".lmstudio/models", "LM Studio"),
            ("Library/Application Support/LM Studio/models", "LM Studio"),
            (".ollama/models/manifests", "Ollama")
        ]
        var roots = defaults.map { (home.appendingPathComponent($0.0), $0.1) }
        roots += extraFolders.map { (URL(fileURLWithPath: $0), "Chosen folder") }
        var seenRoots = Set<String>()
        var results: [String: LocalModel] = [:]
        let fm = FileManager.default

        for (unresolved, origin) in roots {
            let root = unresolved.standardizedFileURL.resolvingSymlinksInPath()
            guard seenRoots.insert(root.path).inserted,
                  fm.fileExists(atPath: root.path) else { continue }
            let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
            guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: resourceKeys,
                                               options: [.skipsPackageDescendants], errorHandler: { _, _ in true }) else { continue }
            var visited = 0
            for case let url as URL in iterator {
                visited += 1
                if visited > 20000 { break } // Bounded scan: never enumerate an entire drive indefinitely.
                let ext = url.pathExtension.lowercased()
                let name = url.lastPathComponent.lowercased()
                let values = try? url.resourceValues(forKeys: Set(resourceKeys))
                if values?.isDirectory == true {
                    if name == ".git" || name == "node_modules" || name == "venv" || name == ".venv" {
                        iterator.skipDescendants()
                    } else if ext == "mlmodelc" || ext == "mlpackage" {
                        results[url.path] = LocalModel(id: url.path, name: title(for: url, root: root),
                                                       format: "Core ML", sizeBytes: 0,
                                                       location: url.path, source: origin)
                        iterator.skipDescendants()
                    }
                    continue
                }
                let validWeight = ["gguf", "safetensors", "onnx", "mlmodel", "mlpackage", "pt", "pth", "ckpt"].contains(ext)
                let validBin = ext == "bin" && (name.contains("pytorch_model") || name == "model.bin")
                let ollamaManifest = origin == "Ollama" && !name.hasPrefix(".") && ext.isEmpty
                guard validWeight || validBin || ollamaManifest else { continue }
                let groupKey: String
                let format: String
                if ollamaManifest {
                    groupKey = url.path
                    format = "Ollama"
                } else if ext == "gguf" || ext == "onnx" || ext == "mlmodel" || ext == "mlpackage" || ext == "mlmodelc" {
                    groupKey = url.path
                    format = ext.uppercased()
                } else {
                    // Group shard files into one installed checkpoint entry.
                    groupKey = checkpointGroup(for: url, root: root)
                    format = ext.uppercased()
                }
                let size = Int64(values?.fileSize ?? 0)
                let label = title(for: URL(fileURLWithPath: groupKey), root: root)
                if let existing = results[groupKey] {
                    results[groupKey] = LocalModel(id: existing.id, name: existing.name,
                                                   format: existing.format, sizeBytes: existing.sizeBytes + size,
                                                   location: existing.location, source: existing.source)
                } else {
                    results[groupKey] = LocalModel(id: groupKey, name: label, format: format,
                                                   sizeBytes: size, location: groupKey, source: origin)
                }
            }
        }
        return results.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func checkpointGroup(for url: URL, root: URL) -> String {
        let path = url.path
        if let range = path.range(of: "/snapshots/") {
            let suffix = path[range.upperBound...]
            if let revision = suffix.split(separator: "/").first {
                return String(path[..<range.upperBound]) + String(revision)
            }
        }
        return url.deletingLastPathComponent().path
    }

    private static func title(for url: URL, root: URL) -> String {
        let components = url.pathComponents
        if let match = components.last(where: { $0.hasPrefix("models--") }) {
            return match.replacingOccurrences(of: "models--", with: "")
                .replacingOccurrences(of: "--", with: "/")
        }
        let name = url.lastPathComponent
        if url.path == root.path { return name }
        if name == "snapshots" || name == "model" || name == "weights" {
            return url.deletingLastPathComponent().lastPathComponent
        }
        return name
    }
}
