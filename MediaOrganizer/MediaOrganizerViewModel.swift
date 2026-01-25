import Foundation
import AppKit
import Combine
import CryptoKit

final class MediaOrganizerViewModel: ObservableObject {
    // MARK: - Published Properties (UI State)
    @Published var sourceURL: URL?
    @Published var destinationURL: URL?
    
    @Published var totalFilesScanned: Int = 0
    @Published var totalMediaFound: Int = 0
    @Published var totalCopiedSuccessfully: Int = 0
    @Published var totalConverted: Int = 0
    @Published var totalSkippedDuplicates: Int = 0
    @Published var errorCount: Int = 0
    
    @Published var isScanning: Bool = false
    @Published var isProcessing: Bool = false
    @Published var statusMessage: String = "Idle"
    @Published var logMessages: [String] = []
    
    /// 0.0...1.0 based on files processed; nil when not running
    @Published var progress: Double? = nil
    
    // Processing settings
    @Published var shouldCopyInsteadOfMove: Bool = true
    @Published var convertToIOSFormat: Bool = true
    @Published var skipDuplicates: Bool = true
    @Published var isDryRun: Bool = false
    @Published var maxConcurrentOperations: Int = 4
    
    // Progress info
    @Published var estimatedTimeRemaining: String?
    @Published var processingSpeed: String?
    @Published var currentFileName: String?
    @Published var availableDiskSpace: String?
    
    // Scan results
    @Published var scanComplete: Bool = false
    @Published var mediaFiles: [MediaFileInfo] = []
    
    struct MediaFileInfo: Identifiable {
        let id = UUID()
        let url: URL
        let type: MediaType
        let size: UInt64
        let creationDate: Date?
        let needsConversion: Bool
        
        enum MediaType {
            case image(String) // original extension
            case video(String)
            
            var isImage: Bool {
                if case .image = self { return true }
                return false
            }
        }
    }
    
    // MARK: - Configuration
    
    private let iOSSupportedImageFormats: Set<String> = ["jpg", "jpeg", "png", "heic", "gif"]
    private let iOSSupportedVideoFormats: Set<String> = ["mp4", "mov"]
    
    private let allImageFormats: Set<String> = [
        "jpg", "jpeg", "png", "heic", "gif", "bmp", "tiff", "tif", "webp"
    ]
    
    private let allVideoFormats: Set<String> = [
        "mp4", "mov", "mkv", "avi", "flv", "wmv", "webm"
    ]
    
    private let fileManager = FileManager.default
    private let maxLogMessages = 1000
    
    // Thread-safe counters and state
    private let counterQueue = DispatchQueue(label: "com.mediaorganizer.counters")
    private var internalScannedCount: Int = 0
    private var internalMediaFoundCount: Int = 0
    private var internalCopiedCount: Int = 0
    private var internalConvertedCount: Int = 0
    private var internalDuplicatesCount: Int = 0
    private var internalErrorCount: Int = 0
    
    // Processing state
    private var operationQueue: OperationQueue?
    private var isCancelled = false
    private var startTime: Date?
    private var processedFileHashes: Set<String> = []
    
    // Undo support
    private var operationLog: [FileOperation] = []
    
    struct FileOperation: Codable {
        let sourceURL: URL
        let destinationURL: URL
        let operationType: OperationType
        let timestamp: Date
        
        enum OperationType: String, Codable {
            case copy
            case move
            case convert
        }
    }
    
    // MARK: - Folder Selection
    
    func pickSourceFolder() {
        if let oldURL = sourceURL {
            oldURL.stopAccessingSecurityScopedResource()
        }
        
        pickFolder { [weak self] url in
            DispatchQueue.main.async {
                self?.sourceURL = url
                self?.scanComplete = false
                self?.mediaFiles = []
            }
        }
    }
    
    func pickDestinationFolder() {
        if let oldURL = destinationURL {
            oldURL.stopAccessingSecurityScopedResource()
        }
        
        pickFolder { [weak self] url in
            DispatchQueue.main.async {
                self?.destinationURL = url
                self?.updateAvailableDiskSpace()
            }
        }
    }
    
    private func pickFolder(completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.canCreateDirectories = false
        
        panel.begin { response in
            guard response == .OK, let url = panel.urls.first else {
                completion(nil)
                return
            }
            _ = url.startAccessingSecurityScopedResource()
            completion(url)
        }
    }
    
    private func updateAvailableDiskSpace() {
        guard let destURL = destinationURL else { return }
        
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let values = try destURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                if let capacity = values.volumeAvailableCapacityForImportantUsage {
                    let formatter = ByteCountFormatter()
                    formatter.allowedUnits = [.useGB, .useMB]
                    formatter.countStyle = .file
                    let spaceString = formatter.string(fromByteCount: Int64(capacity))
                    
                    DispatchQueue.main.async {
                        self?.availableDiskSpace = spaceString
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.appendLog("Could not check disk space: \(error.localizedDescription)")
                }
            }
        }
    }
    
    // MARK: - Scan Logic
    
    func startScan() {
        guard let sourceURL else {
            appendLog("Please select source folder.")
            statusOnMain("Missing source folder")
            return
        }
        
        guard !isScanning && !isProcessing else { return }
        
        isScanning = true
        scanComplete = false
        mediaFiles = []
        totalFilesScanned = 0
        totalMediaFound = 0
        
        counterQueue.sync {
            internalScannedCount = 0
            internalMediaFoundCount = 0
            isCancelled = false
        }
        
        statusOnMain("Scanning folders...")
        appendLog("Starting scan of \(sourceURL.path)")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            
            let sourceAccessGranted = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if sourceAccessGranted {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }
            
            do {
                guard let enumerator = self.fileManager.enumerator(
                    at: sourceURL,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .creationDateKey],
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
                        self.finishScan(withStatus: "Scan Failed")
                    }
                    return
                }
                
                var foundMedia: [MediaFileInfo] = []
                
                for case let item as URL in enumerator {
                    // Check for cancellation
                    let cancelled = self.counterQueue.sync { self.isCancelled }
                    guard !cancelled else { break }
                    
                    guard self.isRegularFile(url: item) else { continue }
                    
                    let scanned = self.counterQueue.sync {
                        self.internalScannedCount += 1
                        return self.internalScannedCount
                    }
                    
                    DispatchQueue.main.async {
                        self.totalFilesScanned = scanned
                    }
                    
                    if let mediaInfo = self.getMediaFileInfo(url: item) {
                        foundMedia.append(mediaInfo)
                        
                        let mediaCount = self.counterQueue.sync {
                            self.internalMediaFoundCount += 1
                            return self.internalMediaFoundCount
                        }
                        
                        DispatchQueue.main.async {
                            self.totalMediaFound = mediaCount
                        }
                    }
                }
                
                DispatchQueue.main.async {
                    self.mediaFiles = foundMedia
                    self.scanComplete = true
                    self.finishScan(withStatus: "Scan Complete")
                    self.appendLog("Found \(foundMedia.count) media files in \(self.totalFilesScanned) total files")
                    
                    // Calculate total size
                    let totalSize = foundMedia.reduce(0) { $0 + $1.size }
                    let formatter = ByteCountFormatter()
                    formatter.allowedUnits = [.useGB, .useMB]
                    formatter.countStyle = .file
                    self.appendLog("Total size: \(formatter.string(fromByteCount: Int64(totalSize)))")
                    
                    // Count conversions needed
                    let needsConversion = foundMedia.filter { $0.needsConversion }.count
                    if needsConversion > 0 {
                        self.appendLog("\(needsConversion) files will be converted to iOS-supported formats")
                    }
                }
                
            } catch {
                DispatchQueue.main.async {
                    self.appendLog("Scan error: \(error.localizedDescription)")
                    self.finishScan(withStatus: "Scan Failed")
                }
            }
        }
    }
    
    private func getMediaFileInfo(url: URL) -> MediaFileInfo? {
        let ext = url.pathExtension.lowercased()
        
        var mediaType: MediaFileInfo.MediaType?
        var needsConversion = false
        
        if allImageFormats.contains(ext) {
            mediaType = .image(ext)
            if convertToIOSFormat {
                needsConversion = !iOSSupportedImageFormats.contains(ext)
            }
        } else if allVideoFormats.contains(ext) {
            mediaType = .video(ext)
            if convertToIOSFormat {
                needsConversion = !iOSSupportedVideoFormats.contains(ext)
            }
        }
        
        guard let type = mediaType else { return nil }
        
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
            let size = values.fileSize.map { UInt64($0) } ?? 0
            let creationDate = values.creationDate
            
            return MediaFileInfo(
                url: url,
                type: type,
                size: size,
                creationDate: creationDate,
                needsConversion: needsConversion
            )
        } catch {
            return nil
        }
    }
    
    private func finishScan(withStatus status: String) {
        isScanning = false
        statusMessage = status
    }
    
    // MARK: - Process Logic
    
    func startProcessing() {
        guard let destinationURL else {
            appendLog("Please select destination folder.")
            statusOnMain("Missing destination folder")
            return
        }
        
        guard scanComplete, !mediaFiles.isEmpty else {
            appendLog("Please run scan first.")
            statusOnMain("No files to process")
            return
        }
        
        guard !isProcessing else { return }
        
        // Clean up orphaned empty placeholder files from previous failed runs
        cleanupOrphanedPlaceholders(in: destinationURL)
        
        // Check disk space
        do {
            try checkDiskSpace(for: mediaFiles, destination: destinationURL)
        } catch {
            appendLog("Insufficient disk space: \(error.localizedDescription)")
            statusOnMain("Insufficient disk space")
            return
        }
        
        isProcessing = true
        progress = 0.0
        totalCopiedSuccessfully = 0
        totalConverted = 0
        totalSkippedDuplicates = 0
        errorCount = 0
        startTime = Date()
        operationLog = []
        processedFileHashes = []
        
        counterQueue.sync {
            internalCopiedCount = 0
            internalConvertedCount = 0
            internalDuplicatesCount = 0
            internalErrorCount = 0
            isCancelled = false
        }
        
        let mode = isDryRun ? "DRY RUN" : (shouldCopyInsteadOfMove ? "COPY" : "MOVE")
        statusOnMain("Processing (\(mode))...")
        appendLog("Starting \(mode.lowercased()) of \(mediaFiles.count) media files")
        
        if isDryRun {
            appendLog("⚠️ DRY RUN MODE - No files will be modified")
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            
            let destAccessGranted = destinationURL.startAccessingSecurityScopedResource()
            defer {
                if destAccessGranted {
                    destinationURL.stopAccessingSecurityScopedResource()
                }
            }
            
            // Create operation queue
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = self.maxConcurrentOperations
            queue.qualityOfService = .userInitiated
            self.operationQueue = queue
            
            let totalFiles = self.mediaFiles.count
            
            // Process files concurrently
            for mediaFile in self.mediaFiles {
                let operation = BlockOperation { [weak self] in
                    guard let self else { return }
                    
                    let cancelled = self.counterQueue.sync { self.isCancelled }
                    guard !cancelled else { return }
                    
                    self.processMediaFile(mediaFile, destinationFolder: destinationURL, totalFiles: totalFiles)
                    
                    // Update progress estimates
                    self.updateProgressEstimates(totalFiles: totalFiles)
                }
                queue.addOperation(operation)
            }
            
            // Wait for completion
            queue.waitUntilAllOperationsAreFinished()
            
            // Save operation log
            if !self.isDryRun {
                self.saveOperationLog()
            }
            
            let wasCancelled = self.counterQueue.sync { self.isCancelled }
            
            DispatchQueue.main.async {
                if wasCancelled {
                    self.finishProcessing(withStatus: "Cancelled")
                } else {
                    let summary = self.isDryRun ? "Dry Run Complete" : "Processing Complete"
                    self.finishProcessing(withStatus: summary)
                    self.appendLog("✅ \(summary): \(self.totalCopiedSuccessfully) processed, \(self.totalConverted) converted, \(self.totalSkippedDuplicates) duplicates skipped, \(self.errorCount) errors")
                }
            }
        }
    }
    
    private func checkDiskSpace(for files: [MediaFileInfo], destination: URL) throws {
        let values = try destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let availableCapacity = values.volumeAvailableCapacityForImportantUsage else {
            throw NSError(domain: "DiskSpaceError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not determine available disk space"])
        }
        
        let totalNeeded = files.reduce(UInt64(0)) { $0 + $1.size }
        
        // Add 20% buffer for safety and conversion overhead
        let neededWithBuffer = UInt64(Double(totalNeeded) * 1.2)
        
        if neededWithBuffer > availableCapacity {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useGB, .useMB]
            formatter.countStyle = .file
            
            let needed = formatter.string(fromByteCount: Int64(neededWithBuffer))
            let available = formatter.string(fromByteCount: Int64(availableCapacity))
            
            throw NSError(domain: "DiskSpaceError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Need \(needed) but only \(available) available"])
        }
    }
    
    private func processMediaFile(_ mediaFile: MediaFileInfo, destinationFolder: URL, totalFiles: Int) {
        let fileName = mediaFile.url.lastPathComponent
        
        DispatchQueue.main.async {
            self.currentFileName = fileName
        }
        
        // Check for duplicates
        if skipDuplicates {
            do {
                let fileHash = try calculateFileHash(url: mediaFile.url)
                
                let isDuplicate = counterQueue.sync {
                    if processedFileHashes.contains(fileHash) {
                        return true
                    }
                    processedFileHashes.insert(fileHash)
                    return false
                }
                
                if isDuplicate {
                    counterQueue.sync { internalDuplicatesCount += 1 }
                    DispatchQueue.main.async {
                        self.totalSkippedDuplicates = self.counterQueue.sync { self.internalDuplicatesCount }
                        self.appendLog("⏭️  Skipped duplicate: \(fileName)")
                    }
                    return
                }
            } catch {
                counterQueue.sync { internalErrorCount += 1 }
                DispatchQueue.main.async {
                    self.errorCount = self.counterQueue.sync { self.internalErrorCount }
                    self.appendLog("❌ Failed to hash \(fileName): \(error.localizedDescription)")
                }
                return
            }
        }
        
        if isDryRun {
            // Dry run mode - just log what would happen
            let action = mediaFile.needsConversion ? "convert & copy" : "copy"
            DispatchQueue.main.async {
                self.appendLog("Would \(action): \(fileName)")
            }
            
            counterQueue.sync { internalCopiedCount += 1 }
            DispatchQueue.main.async {
                self.totalCopiedSuccessfully = self.counterQueue.sync { self.internalCopiedCount }
            }
            return
        }
        
        // Determine if conversion is needed
        do {
            if mediaFile.needsConversion && convertToIOSFormat {
                // Convert file
                let destURL = try convertToIOSFormat(
                    mediaFile: mediaFile,
                    destinationFolder: destinationFolder
                )
                
                counterQueue.sync {
                    internalConvertedCount += 1
                    internalCopiedCount += 1
                }
                
                // Log the operation
                let operation = FileOperation(
                    sourceURL: mediaFile.url,
                    destinationURL: destURL,
                    operationType: .convert,
                    timestamp: Date()
                )
                counterQueue.sync {
                    operationLog.append(operation)
                }
                
                DispatchQueue.main.async {
                    self.totalConverted = self.counterQueue.sync { self.internalConvertedCount }
                    self.totalCopiedSuccessfully = self.counterQueue.sync { self.internalCopiedCount }
                    if case .image(let ext) = mediaFile.type {
                        self.appendLog("🔄 Converted (\(ext)→jpg) & copied: \(fileName)")
                    } else if case .video(let ext) = mediaFile.type {
                        self.appendLog("🔄 Converted (\(ext)→mp4) & copied: \(fileName)")
                    }
                }
            } else {
                // Regular copy/move
                let destURL = try copyOrMoveFile(
                    from: mediaFile.url,
                    to: destinationFolder,
                    shouldCopy: shouldCopyInsteadOfMove
                )
                
                counterQueue.sync { internalCopiedCount += 1 }
                
                // Log the operation
                let operation = FileOperation(
                    sourceURL: mediaFile.url,
                    destinationURL: destURL,
                    operationType: shouldCopyInsteadOfMove ? .copy : .move,
                    timestamp: Date()
                )
                counterQueue.sync {
                    operationLog.append(operation)
                }
                
                DispatchQueue.main.async {
                    self.totalCopiedSuccessfully = self.counterQueue.sync { self.internalCopiedCount }
                    let verb = self.shouldCopyInsteadOfMove ? "Copied" : "Moved"
                    self.appendLog("✅ \(verb): \(fileName)")
                }
            }
            
        } catch {
            counterQueue.sync { internalErrorCount += 1 }
            DispatchQueue.main.async {
                self.errorCount = self.counterQueue.sync { self.internalErrorCount }
                self.appendLog("❌ Failed to process \(fileName): \(error.localizedDescription)")
            }
        }
    }
    
    private func calculateFileHash(url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    private func copyOrMoveFile(from sourceURL: URL, to destinationFolder: URL, shouldCopy: Bool) throws -> URL {
        let destURL = try reserveUniqueFileName(
            baseName: sourceURL.deletingPathExtension().lastPathComponent,
            extension: sourceURL.pathExtension,
            in: destinationFolder
        )
        
        // Preserve attributes
        let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
        
        if shouldCopy {
            try fileManager.copyItem(at: sourceURL, to: destURL)
        } else {
            try fileManager.moveItem(at: sourceURL, to: destURL)
        }
        
        // Reapply attributes
        try? fileManager.setAttributes(attributes, ofItemAtPath: destURL.path)
        
        return destURL
    }
    
    private func convertToIOSFormat(mediaFile: MediaFileInfo, destinationFolder: URL) throws -> URL {
        switch mediaFile.type {
        case .image:
            return try convertImageToJPEG(sourceURL: mediaFile.url, destinationFolder: destinationFolder)
        case .video:
            return try convertVideoToMP4(sourceURL: mediaFile.url, destinationFolder: destinationFolder)
        }
    }
    
    private func convertImageToJPEG(sourceURL: URL, destinationFolder: URL) throws -> URL {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        
        let destURL = try reserveUniqueFileName(
            baseName: baseName,
            extension: "jpg",
            in: destinationFolder
        )
        
        // Use sips for conversion
        let process = Process()
        
        // Find sips executable
        guard let sipsPath = findExecutable(name: "sips", paths: ["/usr/bin/sips"]) else {
            throw NSError(domain: "ConversionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "sips tool not found"])
        }
        
        process.executableURL = URL(fileURLWithPath: sipsPath)
        process.arguments = [
            "-s", "format", "jpeg",
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
            throw NSError(domain: "ConversionError", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Image conversion failed: \(errorMessage)"])
        }
        
        // Verify file was created and has reasonable size
        let attributes = try fileManager.attributesOfItem(atPath: destURL.path)
        guard let fileSize = attributes[.size] as? UInt64, fileSize > 100 else {
            throw NSError(domain: "ConversionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Converted file appears corrupted"])
        }
        
        // Preserve original file dates
        if let originalAttrs = try? fileManager.attributesOfItem(atPath: sourceURL.path) {
            try? fileManager.setAttributes(originalAttrs, ofItemAtPath: destURL.path)
        }
        
        return destURL
    }
    
    private func convertVideoToMP4(sourceURL: URL, destinationFolder: URL) throws -> URL {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        
        let destURL = try reserveUniqueFileName(
            baseName: baseName,
            extension: "mp4",
            in: destinationFolder
        )
        
        // Use ffmpeg for video conversion (if available)
        guard let ffmpegPath = findExecutable(name: "ffmpeg", paths: [
            "/usr/local/bin/ffmpeg",
            "/opt/homebrew/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]) else {
            // Fallback: just copy if ffmpeg not available
            appendLog("⚠️  ffmpeg not found, copying video without conversion")
            try fileManager.copyItem(at: sourceURL, to: destURL)
            return destURL
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = [
            "-i", sourceURL.path,
            "-c:v", "libx264",
            "-c:a", "aac",
            "-strict", "experimental",
            destURL.path
        ]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "ConversionError", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Video conversion failed: \(errorMessage)"])
        }
        
        // Verify file
        let attributes = try fileManager.attributesOfItem(atPath: destURL.path)
        guard let fileSize = attributes[.size] as? UInt64, fileSize > 1000 else {
            throw NSError(domain: "ConversionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Converted video appears corrupted"])
        }
        
        return destURL
    }
    
    private func findExecutable(name: String, paths: [String]) -> String? {
        return paths.first { fileManager.fileExists(atPath: $0) }
    }
    
    private func reserveUniqueFileName(baseName: String, extension ext: String, in folder: URL) throws -> URL {
        return counterQueue.sync {
            var candidate = folder.appendingPathComponent("\(baseName).\(ext)")
            var index = 1
            
            while fileManager.fileExists(atPath: candidate.path) {
                candidate = folder.appendingPathComponent("\(baseName)_\(index).\(ext)")
                index += 1
            }
            
            // Don't create a placeholder - just return the safe name
            // The actual copy/move operation will create the file
            return candidate
        }
    }
    
    private func updateProgressEstimates(totalFiles: Int) {
        guard let start = startTime else { return }
        
        let processed = counterQueue.sync { internalCopiedCount }
        guard processed > 0 else { return }
        
        let elapsed = Date().timeIntervalSince(start)
        let filesPerSecond = Double(processed) / elapsed
        let remaining = totalFiles - processed
        let estimatedSecondsRemaining = Double(remaining) / filesPerSecond
        
        DispatchQueue.main.async {
            self.progress = Double(processed) / Double(totalFiles)
            
            // Format speed
            self.processingSpeed = String(format: "%.1f files/sec", filesPerSecond)
            
            // Format time remaining
            if estimatedSecondsRemaining < 60 {
                self.estimatedTimeRemaining = String(format: "%.0f sec", estimatedSecondsRemaining)
            } else if estimatedSecondsRemaining < 3600 {
                self.estimatedTimeRemaining = String(format: "%.1f min", estimatedSecondsRemaining / 60)
            } else {
                self.estimatedTimeRemaining = String(format: "%.1f hrs", estimatedSecondsRemaining / 3600)
            }
        }
    }
    
    private func saveOperationLog() {
        guard !operationLog.isEmpty else { return }
        
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            
            let data = try encoder.encode(operationLog)
            
            let logsFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let logFile = logsFolder.appendingPathComponent("media_organizer_log_\(Date().timeIntervalSince1970).json")
            
            try data.write(to: logFile)
            
            DispatchQueue.main.async {
                self.appendLog("📝 Operation log saved to: \(logFile.path)")
            }
        } catch {
            DispatchQueue.main.async {
                self.appendLog("⚠️  Could not save operation log: \(error.localizedDescription)")
            }
        }
    }
    
    private func finishProcessing(withStatus status: String) {
        isProcessing = false
        progress = nil
        statusMessage = status
        currentFileName = nil
        estimatedTimeRemaining = nil
        processingSpeed = nil
        startTime = nil
    }
    
    // MARK: - Cancellation
    
    func cancelOperation() {
        guard isScanning || isProcessing else { return }
        
        counterQueue.sync {
            isCancelled = true
        }
        
        operationQueue?.cancelAllOperations()
        
        DispatchQueue.main.async {
            self.appendLog("🛑 Operation cancelled by user")
            if self.isScanning {
                self.finishScan(withStatus: "Cancelled")
            } else {
                self.finishProcessing(withStatus: "Cancelled")
            }
        }
    }
    
    // MARK: - Cleanup Helpers
    
    /// Removes orphaned zero-byte placeholder files from previous failed runs
    private func cleanupOrphanedPlaceholders(in directory: URL) {
        let fileManager = FileManager.default
        
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return
        }
        
        var cleanedCount = 0
        for fileURL in contents {
            do {
                let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
                let fileSize = attributes[.size] as? NSNumber
                
                // Remove zero-byte files (orphaned placeholders)
                if fileSize?.intValue == 0 {
                    try fileManager.removeItem(at: fileURL)
                    cleanedCount += 1
                }
            } catch {
                // Silently skip files we can't access
                continue
            }
        }
        
        if cleanedCount > 0 {
            appendLog("🧹 Cleaned up \(cleanedCount) orphaned placeholder file(s)")
        }
    }
    
    // MARK: - Undo
    
    func undoLastOperation() {
        guard !operationLog.isEmpty else {
            appendLog("No operations to undo")
            return
        }
        
        appendLog("⏮️  Starting undo...")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            
            var successCount = 0
            var failCount = 0
            
            // Reverse the operations
            for operation in self.operationLog.reversed() {
                do {
                    // Delete the destination file
                    if self.fileManager.fileExists(atPath: operation.destinationURL.path) {
                        try self.fileManager.removeItem(at: operation.destinationURL)
                        successCount += 1
                    }
                    
                    // If it was a move (not copy), restore the original
                    if operation.operationType == .move {
                        // Note: This is why COPY is safer - we can't restore moved files
                        DispatchQueue.main.async {
                            self.appendLog("⚠️  Cannot restore moved file: \(operation.sourceURL.lastPathComponent)")
                        }
                    }
                } catch {
                    failCount += 1
                    DispatchQueue.main.async {
                        self.appendLog("❌ Failed to undo \(operation.destinationURL.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }
            
            DispatchQueue.main.async {
                self.operationLog = []
                self.appendLog("✅ Undo complete: \(successCount) deleted, \(failCount) failed")
            }
        }
    }
    
    // MARK: - Helpers
    
    private func isRegularFile(url: URL) -> Bool {
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            return values.isDirectory == false
        } catch {
            return false
        }
    }
    
    private func appendLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        DispatchQueue.main.async {
            self.logMessages.append("[\(timestamp)] \(message)")
            
            // Limit log size
            if self.logMessages.count > self.maxLogMessages {
                self.logMessages.removeFirst(self.logMessages.count - self.maxLogMessages)
            }
        }
    }
    
    private func statusOnMain(_ status: String) {
        DispatchQueue.main.async {
            self.statusMessage = status
        }
    }
    
    // MARK: - Export Logs
    
    func exportLogs() throws {
        let logsFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logFile = logsFolder.appendingPathComponent("media_organizer_logs_\(Date().timeIntervalSince1970).txt")
        
        let logContent = logMessages.joined(separator: "\n")
        try logContent.write(to: logFile, atomically: true, encoding: .utf8)
        
        appendLog("📄 Logs exported to: \(logFile.path)")
        
        // Open in Finder
        NSWorkspace.shared.activateFileViewerSelecting([logFile])
    }
}
