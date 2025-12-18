import Foundation
import AppKit
import Combine

final class MediaOrganizerViewModel: ObservableObject {
    // MARK: - Published Properties (UI State)
    @Published var sourceURL: URL?
    @Published var destinationURL: URL?
    
    @Published var totalFilesScanned: Int = 0
    @Published var totalMediaFound: Int = 0
    @Published var totalMovedSuccessfully: Int = 0
    @Published var totalConverted: Int = 0
    
    @Published var isRunning: Bool = false
    @Published var statusMessage: String = "Idle"
    @Published var logMessages: [String] = []
    
    /// 0.0...1.0 based on files scanned; nil when not running
    @Published var progress: Double? = nil
    
    // Image conversion settings
    @Published var convertImages: Bool = false
    @Published var targetImageFormat: ImageFormat = .jpeg
    
    enum ImageFormat: String, CaseIterable {
        case jpeg = "jpeg"
        case png = "png"
        case tiff = "tiff"
        case bmp = "bmp"
        
        var displayName: String {
            return rawValue.uppercased()
        }
        
        var fileExtension: String {
            switch self {
            case .jpeg: return "jpg"
            case .png: return "png"
            case .tiff: return "tiff"
            case .bmp: return "bmp"
            }
        }
    }
    
    // MARK: - Configuration
    
    private let mediaExtensions: Set<String> = [
        // Images
        "jpg", "jpeg", "png", "heic", "gif", "bmp", "tiff", "tif", "webp",
        // Videos
        "mp4", "mov", "mkv", "avi", "flv", "wmv", "webm"
    ]
    
    private let fileManager = FileManager.default
    
    // MARK: - Folder Selection
    
    func pickSourceFolder() {
        // Stop accessing previous source folder if any
        if let oldURL = sourceURL {
            oldURL.stopAccessingSecurityScopedResource()
        }
        
        pickFolder { [weak self] url in
            DispatchQueue.main.async {
                self?.sourceURL = url
            }
        }
    }
    
    func pickDestinationFolder() {
        // Stop accessing previous destination folder if any
        if let oldURL = destinationURL {
            oldURL.stopAccessingSecurityScopedResource()
        }
        
        pickFolder { [weak self] url in
            DispatchQueue.main.async {
                self?.destinationURL = url
            }
        }
    }
    
    private func pickFolder(completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        // Request security-scoped access for sandboxed apps
        panel.canCreateDirectories = false
        
        panel.begin { response in
            guard response == .OK, let url = panel.urls.first else {
                completion(nil)
                return
            }
            // Start accessing security-scoped resource immediately
            _ = url.startAccessingSecurityScopedResource()
            completion(url)
        }
    }
    
    // MARK: - Scan & Move Logic
    
    func startScanAndMove() {
        guard let sourceURL, let destinationURL else {
            appendLog("Please select both source and destination folders.")
            statusOnMain("Missing folders")
            return
        }
        
        guard !isRunning else { return }
        
        isRunning = true
        progress = 0.0
        totalFilesScanned = 0
        totalMediaFound = 0
        totalMovedSuccessfully = 0
        totalConverted = 0
        statusOnMain("Scanning...")
        appendLog("Starting scan from \(sourceURL.path) to \(destinationURL.path)")
        
        let sourcePath = sourceURL.path
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            
            // Start accessing security-scoped resources (required for sandboxed apps)
            // Returns false if URL is not security-scoped or already accessed, which is OK
            let sourceAccessGranted = sourceURL.startAccessingSecurityScopedResource()
            let destAccessGranted = destinationURL.startAccessingSecurityScopedResource()
            
            defer {
                // Always stop accessing security-scoped resources when done
                if sourceAccessGranted {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
                if destAccessGranted {
                    destinationURL.stopAccessingSecurityScopedResource()
                }
            }
            
            do {
                guard let enumerator = self.fileManager.enumerator(
                    at: sourceURL,
                    includingPropertiesForKeys: [.isDirectoryKey, .contentTypeKey, .creationDateKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles],
                    errorHandler: { url, error in
                        DispatchQueue.main.async {
                            self.appendLog("Error accessing \(url.path): \(error.localizedDescription)")
                        }
                        return true
                    }
                ) else {
                    DispatchQueue.main.async {
                        self.appendLog("Failed to create enumerator for source folder.")
                        self.finish(withStatus: "Failed")
                    }
                    return
                }
                
                // First pass: count total files (for progress)
                var allFileURLs: [URL] = []
                for case let item as URL in enumerator {
                    if self.isRegularFile(url: item) {
                        allFileURLs.append(item)
                    }
                }
                
                let totalFiles = allFileURLs.count
                if totalFiles == 0 {
                    DispatchQueue.main.async {
                        self.appendLog("No files found in source folder.")
                        self.totalFilesScanned = 0
                        self.progress = nil
                        self.finish(withStatus: "Completed (no files)")
                    }
                    return
                }
                
                var scannedCount = 0
                for fileURL in allFileURLs {
                    scannedCount += 1
                    let relativePath = fileURL.path.replacingOccurrences(of: sourcePath, with: "")
                    
                    let isMedia = self.isMediaFile(url: fileURL)
                    DispatchQueue.main.async {
                        self.totalFilesScanned = scannedCount
                        self.progress = Double(scannedCount) / Double(totalFiles)
                    }
                    
                    guard isMedia else { continue }
                    
                    DispatchQueue.main.async {
                        self.totalMediaFound += 1
                    }
                    
                    do {
                        let isImage = self.isImageFile(url: fileURL)
                        let shouldConvert = self.convertImages && isImage
                        
                        let finalDestURL: URL
                        let tempURL: URL?
                        
                        if shouldConvert {
                            // Convert image first, then move converted file
                            let convertedURL = try self.convertImage(
                                sourceURL: fileURL,
                                destinationFolder: destinationURL,
                                format: self.targetImageFormat
                            )
                            finalDestURL = convertedURL
                            tempURL = nil
                        } else {
                            // Regular move
                            finalDestURL = try self.destinationURLForFile(
                                originalURL: fileURL,
                                destinationFolder: destinationURL
                            )
                            tempURL = nil
                            
                            // Preserve attributes before move
                            let attributes = try self.fileManager.attributesOfItem(atPath: fileURL.path)
                            
                            try self.fileManager.moveItem(at: fileURL, to: finalDestURL)
                            
                            // Reapply attributes where possible (for cross-volume moves)
                            try self.fileManager.setAttributes(attributes, ofItemAtPath: finalDestURL.path)
                        }
                        
                        DispatchQueue.main.async {
                            self.totalMovedSuccessfully += 1
                            if shouldConvert {
                                self.totalConverted += 1
                                let originalExt = fileURL.pathExtension.lowercased()
                                let targetExt = self.targetImageFormat.fileExtension
                                self.appendLog("Converted (\(originalExt)→\(targetExt)) & moved: \(relativePath) → \(finalDestURL.lastPathComponent)")
                            } else {
                                self.appendLog("Moved: \(relativePath) → \(finalDestURL.lastPathComponent)")
                            }
                        }
                    } catch {
                        DispatchQueue.main.async {
                            self.appendLog("Failed to process \(relativePath): \(error.localizedDescription)")
                        }
                    }
                }
                
                DispatchQueue.main.async {
                    self.finish(withStatus: "Completed")
                }
            } catch {
                DispatchQueue.main.async {
                    self.appendLog("Unexpected error: \(error.localizedDescription)")
                    self.finish(withStatus: "Failed")
                }
            }
        }
    }
    
    private func isRegularFile(url: URL) -> Bool {
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            return values.isDirectory == false
        } catch {
            return false
        }
    }
    
    private func isMediaFile(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return mediaExtensions.contains(ext)
    }
    
    private func isImageFile(url: URL) -> Bool {
        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "gif", "bmp", "tiff", "tif", "webp"]
        let ext = url.pathExtension.lowercased()
        return imageExtensions.contains(ext)
    }
    
    private func destinationURLForFile(originalURL: URL, destinationFolder: URL) throws -> URL {
        let baseName = originalURL.deletingPathExtension().lastPathComponent
        let ext = originalURL.pathExtension
        
        var candidate = destinationFolder.appendingPathComponent("\(baseName).\(ext)")
        
        var index = 1
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = destinationFolder.appendingPathComponent("\(baseName)_\(index).\(ext)")
            index += 1
        }
        
        return candidate
    }
    
    // MARK: - Image Conversion
    
    private func convertImage(sourceURL: URL, destinationFolder: URL, format: ImageFormat) throws -> URL {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let targetExt = format.fileExtension
        
        // Generate destination URL with target extension
        var destURL = destinationFolder.appendingPathComponent("\(baseName).\(targetExt)")
        
        // Handle name conflicts
        var index = 1
        while fileManager.fileExists(atPath: destURL.path) {
            destURL = destinationFolder.appendingPathComponent("\(baseName)_\(index).\(targetExt)")
            index += 1
        }
        
        // Use sips command-line tool for conversion
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        process.arguments = [
            "-s", "format", format.rawValue,
            sourceURL.path,
            "--out", destURL.path
        ]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "ImageConversionError", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "sips conversion failed: \(errorMessage)"])
        }
        
        // Verify converted file exists
        guard fileManager.fileExists(atPath: destURL.path) else {
            throw NSError(domain: "ImageConversionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Converted file was not created"])
        }
        
        // Preserve original file attributes
        do {
            let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
            try fileManager.setAttributes(attributes, ofItemAtPath: destURL.path)
        } catch {
            // Log but don't fail if we can't preserve attributes
            DispatchQueue.main.async {
                self.appendLog("Warning: Could not preserve attributes for \(destURL.lastPathComponent)")
            }
        }
        
        // Delete original file after successful conversion
        try fileManager.removeItem(at: sourceURL)
        
        return destURL
    }
    
    // MARK: - Helpers
    
    private func appendLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logMessages.append("[\(timestamp)] \(message)")
    }
    
    private func statusOnMain(_ status: String) {
        DispatchQueue.main.async {
            self.statusMessage = status
        }
    }
    
    private func finish(withStatus status: String) {
        isRunning = false
        progress = nil
        statusMessage = status
    }
}


