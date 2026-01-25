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
    @Published var totalSkipped: Int = 0
    @Published var errorCount: Int = 0
    
    @Published var isScanning: Bool = false
    @Published var isProcessing: Bool = false
    @Published var statusMessage: String = "Idle"
    @Published var logMessages: [String] = []
    
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
    @Published var totalSizeFormatted: String = "-"
    
    // Scan results
    @Published var scanComplete: Bool = false
    @Published var mediaFiles: [MediaFileInfo] = []
    
    // Alert handling
    @Published var showAlert: Bool = false
    @Published var alertMessage: String?
    
    // Validation
    @Published var validationWarning: String?
    
    // MARK: - Computed Properties for UI State
    
    var isScanDisabled: Bool {
        isScanning || isProcessing || sourceURL == nil
    }
    
    var isProcessDisabled: Bool {
        !scanComplete || isProcessing || destinationURL == nil || validationWarning != nil || mediaFiles.isEmpty
    }
    
    var canUndo: Bool {
        !operationLog.isEmpty && !isProcessing
    }
    
    // MARK: - Data Types
    
    struct MediaFileInfo: Identifiable, Sendable {
        let id = UUID()
        let url: URL
        let type: MediaType
        let size: UInt64
        let creationDate: Date?
        let needsConversion: Bool
        
        enum MediaType: Sendable {
            case image(String)
            case video(String)
            
            var isImage: Bool {
                if case .image = self { return true }
                return false
            }
        }
    }
    
    // MARK: - Configuration
    
    private let iOSSupportedImageFormats: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "gif"]
    private let iOSSupportedVideoFormats: Set<String> = ["mp4", "mov", "m4v"]
    
    private let allImageFormats: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "bmp", "tiff", "tif", "webp", "raw", "cr2", "nef", "arw", "dng"
    ]
    
    private let allVideoFormats: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "avi", "flv", "wmv", "webm", "mpg", "mpeg", "3gp"
    ]
    
    private let fileManager = FileManager.default
    private let maxLogMessages = 500
    
    // Thread-safe state management
    private let stateQueue = DispatchQueue(label: "com.mediaorganizer.state", attributes: .concurrent)
    private var _internalState = InternalState()
    
    private struct InternalState {
        var scannedCount: Int = 0
        var mediaFoundCount: Int = 0
        var copiedCount: Int = 0
        var convertedCount: Int = 0
        var duplicatesCount: Int = 0
        var skippedCount: Int = 0
        var errorCount: Int = 0
        var isCancelled: Bool = false
        var processedFileHashes: Set<String> = []
        var reservedFileNames: Set<String> = []
    }
    
    // Processing state
    private var operationQueue: OperationQueue?
    private var startTime: Date?
    
    // Bookmark data for security-scoped access
    private var sourceBookmarkData: Data?
    private var destinationBookmarkData: Data?
    
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
    
    // MARK: - Thread-Safe State Access
    
    private func readState<T>(_ keyPath: KeyPath<InternalState, T>) -> T {
        stateQueue.sync { _internalState[keyPath: keyPath] }
    }
    
    private func writeState<T>(_ keyPath: WritableKeyPath<InternalState, T>, value: T) {
        stateQueue.async(flags: .barrier) { self._internalState[keyPath: keyPath] = value }
    }
    
    private func modifyState(_ modification: @escaping (inout InternalState) -> Void) {
        stateQueue.async(flags: .barrier) { modification(&self._internalState) }
    }
    
    private func modifyStateSync<T>(_ modification: (inout InternalState) -> T) -> T {
        stateQueue.sync(flags: .barrier) { modification(&self._internalState) }
    }
    
    // MARK: - Validation
    
    private func validateConfiguration() {
        guard let source = sourceURL, let destination = destinationURL else {
            validationWarning = nil
            return
        }
        
        let sourcePath = source.standardizedFileURL.path
        let destPath = destination.standardizedFileURL.path
        
        if sourcePath == destPath {
            validationWarning = "Source and destination cannot be the same folder"
            return
        }
        
        if destPath.hasPrefix(sourcePath + "/") {
            validationWarning = "Destination cannot be inside the source folder"
            return
        }
        
        if sourcePath.hasPrefix(destPath + "/") {
            validationWarning = "Source cannot be inside the destination folder"
            return
        }
        
        validationWarning = nil
    }
    
    // MARK: - Folder Selection
    
    func pickSourceFolder() {
        pickFolder { [weak self] url in
            guard let self, let url else { return }
            
            // Create bookmark for persistent access
            do {
                let bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                self.sourceBookmarkData = bookmarkData
            } catch {
                self.appendLog("Warning: Could not create bookmark for source: \(error.localizedDescription)")
            }
            
            DispatchQueue.main.async {
                self.sourceURL = url
                self.scanComplete = false
                self.mediaFiles = []
                self.totalSizeFormatted = "-"
                self.validateConfiguration()
            }
        }
    }
    
    func pickDestinationFolder() {
        pickFolder { [weak self] url in
            guard let self, let url else { return }
            
            // Create bookmark for persistent access
            do {
                let bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                self.destinationBookmarkData = bookmarkData
            } catch {
                self.appendLog("Warning: Could not create bookmark for destination: \(error.localizedDescription)")
            }
            
            DispatchQueue.main.async {
                self.destinationURL = url
                self.updateAvailableDiskSpace()
                self.validateConfiguration()
            }
        }
    }
    
    private func pickFolder(completion: @escaping (URL?) -> Void) {
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Select"
            panel.canCreateDirectories = true
            panel.message = "Select a folder"
            
            panel.begin { response in
                guard response == .OK, let url = panel.urls.first else {
                    completion(nil)
                    return
                }
                
                _ = url.startAccessingSecurityScopedResource()
                completion(url)
            }
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
                    let spaceString = formatter.string(fromByteCount: capacity)
                    
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
            showError("Please select source folder.")
            return
        }
        
        guard !isScanning && !isProcessing else { return }
        
        isScanning = true
        scanComplete = false
        mediaFiles = []
        totalFilesScanned = 0
        totalMediaFound = 0
        totalSizeFormatted = "-"
        
        modifyState { state in
            state.scannedCount = 0
            state.mediaFoundCount = 0
            state.isCancelled = false
        }
        
        statusOnMain("Scanning folders...")
        appendLog("Starting scan of: \(sourceURL.path)")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            
            let accessGranted = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if accessGranted {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }
            
            guard let enumerator = self.fileManager.enumerator(
                at: sourceURL,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey, .isReadableKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                DispatchQueue.main.async {
                    self.appendLog("❌ Failed to create folder enumerator")
                    self.finishScan(withStatus: "Scan Failed")
                }
                return
            }
            
            var foundMedia: [MediaFileInfo] = []
            
            for case let fileURL as URL in enumerator {
                let cancelled = self.readState(\.isCancelled)
                guard !cancelled else { break }
                
                // Check if it's a regular file
                guard self.isRegularFile(url: fileURL) else { continue }
                
                let scanned = self.modifyStateSync { state -> Int in
                    state.scannedCount += 1
                    return state.scannedCount
                }
                
                // Update UI periodically
                if scanned % 100 == 0 {
                    DispatchQueue.main.async {
                        self.totalFilesScanned = scanned
                    }
                }
                
                if let mediaInfo = self.getMediaFileInfo(url: fileURL) {
                    foundMedia.append(mediaInfo)
                    
                    let mediaCount = self.modifyStateSync { state -> Int in
                        state.mediaFoundCount += 1
                        return state.mediaFoundCount
                    }
                    
                    if mediaCount % 100 == 0 {
                        DispatchQueue.main.async {
                            self.totalMediaFound = mediaCount
                        }
                    }
                }
            }
            
            let finalScanned = self.readState(\.scannedCount)
            let finalFound = self.readState(\.mediaFoundCount)
            
            DispatchQueue.main.async {
                self.totalFilesScanned = finalScanned
                self.totalMediaFound = finalFound
                self.mediaFiles = foundMedia
                self.scanComplete = true
                self.finishScan(withStatus: "Scan Complete")
                self.appendLog("✅ Found \(foundMedia.count) media files in \(finalScanned) total files")
                
                // Calculate total size
                let totalSize = foundMedia.reduce(UInt64(0)) { $0 + $1.size }
                let formatter = ByteCountFormatter()
                formatter.allowedUnits = [.useGB, .useMB]
                formatter.countStyle = .file
                self.totalSizeFormatted = formatter.string(fromByteCount: Int64(totalSize))
                self.appendLog("Total size: \(self.totalSizeFormatted)")
                
                // Count conversions needed
                let needsConversion = foundMedia.filter { $0.needsConversion }.count
                if needsConversion > 0 && self.convertToIOSFormat {
                    self.appendLog("ℹ️ \(needsConversion) files will need conversion")
                }
            }
        }
    }
    
    private func getMediaFileInfo(url: URL) -> MediaFileInfo? {
        let ext = url.pathExtension.lowercased()
        
        guard !ext.isEmpty else { return nil }
        
        var mediaType: MediaFileInfo.MediaType?
        var needsConversion = false
        
        if allImageFormats.contains(ext) {
            mediaType = .image(ext)
            needsConversion = !iOSSupportedImageFormats.contains(ext)
        } else if allVideoFormats.contains(ext) {
            mediaType = .video(ext)
            needsConversion = !iOSSupportedVideoFormats.contains(ext)
        }
        
        guard let type = mediaType else { return nil }
        
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
            let size = UInt64(values.fileSize ?? 0)
            let creationDate = values.creationDate
            
            // Skip zero-byte files
            guard size > 0 else { return nil }
            
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
        guard let sourceURL, let destinationURL else {
            showError("Please select both source and destination folders.")
            return
        }
        
        validateConfiguration()
        if let warning = validationWarning {
            showError(warning)
            return
        }
        
        guard scanComplete, !mediaFiles.isEmpty else {
            showError("Please run scan first.")
            return
        }
        
        guard !isProcessing else { return }
        
        // Check disk space
        do {
            try checkDiskSpace(for: mediaFiles, destination: destinationURL)
        } catch {
            showError(error.localizedDescription)
            return
        }
        
        isProcessing = true
        progress = 0.0
        totalCopiedSuccessfully = 0
        totalConverted = 0
        totalSkippedDuplicates = 0
        totalSkipped = 0
        errorCount = 0
        startTime = Date()
        operationLog = []
        
        modifyState { state in
            state.copiedCount = 0
            state.convertedCount = 0
            state.duplicatesCount = 0
            state.skippedCount = 0
            state.errorCount = 0
            state.isCancelled = false
            state.processedFileHashes = []
            state.reservedFileNames = []
        }
        
        let mode = isDryRun ? "DRY RUN" : (shouldCopyInsteadOfMove ? "COPY" : "MOVE")
        statusOnMain("Processing (\(mode))...")
        appendLog("🚀 Starting \(mode) of \(mediaFiles.count) files")
        appendLog("Source: \(sourceURL.path)")
        appendLog("Destination: \(destinationURL.path)")
        
        if isDryRun {
            appendLog("⚠️ DRY RUN - No files will be modified")
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            
            // Start security-scoped access
            let sourceAccess = sourceURL.startAccessingSecurityScopedResource()
            let destAccess = destinationURL.startAccessingSecurityScopedResource()
            
            defer {
                if sourceAccess { sourceURL.stopAccessingSecurityScopedResource() }
                if destAccess { destinationURL.stopAccessingSecurityScopedResource() }
            }
            
            // Create operation queue for concurrent processing
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = self.maxConcurrentOperations
            queue.qualityOfService = .userInitiated
            self.operationQueue = queue
            
            let totalFiles = self.mediaFiles.count
            var processedCount = 0
            let processedLock = NSLock()
            
            for mediaFile in self.mediaFiles {
                let operation = BlockOperation { [weak self] in
                    guard let self else { return }
                    
                    let cancelled = self.readState(\.isCancelled)
                    guard !cancelled else { return }
                    
                    self.processMediaFile(mediaFile, destinationFolder: destinationURL)
                    
                    // Update progress
                    processedLock.lock()
                    processedCount += 1
                    let currentProcessed = processedCount
                    processedLock.unlock()
                    
                    self.updateProgressEstimates(processed: currentProcessed, total: totalFiles)
                }
                queue.addOperation(operation)
            }
            
            // Wait for all operations to complete
            queue.waitUntilAllOperationsAreFinished()
            
            // Save operation log if not dry run
            if !self.isDryRun && !self.operationLog.isEmpty {
                self.saveOperationLog()
            }
            
            let wasCancelled = self.readState(\.isCancelled)
            let finalCopied = self.readState(\.copiedCount)
            let finalConverted = self.readState(\.convertedCount)
            let finalDuplicates = self.readState(\.duplicatesCount)
            let finalSkipped = self.readState(\.skippedCount)
            let finalErrors = self.readState(\.errorCount)
            
            DispatchQueue.main.async {
                self.totalCopiedSuccessfully = finalCopied
                self.totalConverted = finalConverted
                self.totalSkippedDuplicates = finalDuplicates
                self.totalSkipped = finalSkipped
                self.errorCount = finalErrors
                
                if wasCancelled {
                    self.finishProcessing(withStatus: "Cancelled")
                    self.appendLog("🛑 Processing cancelled")
                } else {
                    let status = self.isDryRun ? "Dry Run Complete" : "Processing Complete"
                    self.finishProcessing(withStatus: status)
                    self.appendLog("✅ \(status)")
                    self.appendLog("   Processed: \(finalCopied), Converted: \(finalConverted)")
                    self.appendLog("   Duplicates: \(finalDuplicates), Skipped: \(finalSkipped), Errors: \(finalErrors)")
                }
            }
        }
    }
    
    private func checkDiskSpace(for files: [MediaFileInfo], destination: URL) throws {
        let values = try destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let availableCapacity = values.volumeAvailableCapacityForImportantUsage else {
            throw NSError(domain: "DiskSpace", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not determine available disk space"])
        }
        
        let totalNeeded = files.reduce(UInt64(0)) { $0 + $1.size }
        let neededWithBuffer = UInt64(Double(totalNeeded) * 1.3) // 30% buffer
        
        if neededWithBuffer > availableCapacity {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useGB, .useMB]
            formatter.countStyle = .file
            
            let needed = formatter.string(fromByteCount: Int64(neededWithBuffer))
            let available = formatter.string(fromByteCount: Int64(availableCapacity))
            
            throw NSError(domain: "DiskSpace", code: -1, userInfo: [NSLocalizedDescriptionKey: "Insufficient disk space. Need ~\(needed) but only \(available) available"])
        }
    }
    
    private func processMediaFile(_ mediaFile: MediaFileInfo, destinationFolder: URL) {
        let fileName = mediaFile.url.lastPathComponent
        
        DispatchQueue.main.async {
            self.currentFileName = fileName
        }
        
        // Verify file still exists and is readable
        guard fileManager.fileExists(atPath: mediaFile.url.path),
              fileManager.isReadableFile(atPath: mediaFile.url.path) else {
            incrementError()
            appendLog("❌ File not accessible: \(fileName)")
            return
        }
        
        // Check for duplicates if enabled
        if skipDuplicates {
            do {
                let fileHash = try calculateFileHashStreaming(url: mediaFile.url)
                
                let isDuplicate = modifyStateSync { state -> Bool in
                    if state.processedFileHashes.contains(fileHash) {
                        state.duplicatesCount += 1
                        return true
                    }
                    state.processedFileHashes.insert(fileHash)
                    return false
                }
                
                if isDuplicate {
                    updateDuplicatesUI()
                    return
                }
            } catch {
                // If hashing fails, log warning but continue with the copy
                appendLog("⚠️ Hash failed for \(fileName), proceeding anyway")
            }
        }
        
        // Dry run mode
        if isDryRun {
            let action = (mediaFile.needsConversion && convertToIOSFormat) ? "convert & copy" : (shouldCopyInsteadOfMove ? "copy" : "move")
            appendLog("Would \(action): \(fileName)")
            incrementCopied()
            return
        }
        
        // Process the file
        do {
            let needsConversion = mediaFile.needsConversion && convertToIOSFormat
            
            if needsConversion {
                let destURL = try convertFile(mediaFile: mediaFile, destinationFolder: destinationFolder)
                logOperation(source: mediaFile.url, destination: destURL, type: .convert)
                incrementConverted()
                incrementCopied()
                
                if case .image(let ext) = mediaFile.type {
                    appendLog("🔄 Converted \(ext)→jpg: \(fileName)")
                } else if case .video(let ext) = mediaFile.type {
                    appendLog("🔄 Converted \(ext)→mp4: \(fileName)")
                }
            } else {
                let destURL = try copyOrMoveFile(from: mediaFile.url, to: destinationFolder)
                logOperation(source: mediaFile.url, destination: destURL, type: shouldCopyInsteadOfMove ? .copy : .move)
                incrementCopied()
            }
            
        } catch {
            incrementError()
            appendLog("❌ \(fileName): \(error.localizedDescription)")
        }
    }
    
    // MARK: - File Operations
    
    private func copyOrMoveFile(from sourceURL: URL, to destinationFolder: URL) throws -> URL {
        let destURL = getUniqueDestinationURL(
            baseName: sourceURL.deletingPathExtension().lastPathComponent,
            extension: sourceURL.pathExtension,
            in: destinationFolder
        )
        
        // Get original attributes before copy
        let attributes = try? fileManager.attributesOfItem(atPath: sourceURL.path)
        
        if shouldCopyInsteadOfMove {
            try fileManager.copyItem(at: sourceURL, to: destURL)
        } else {
            try fileManager.moveItem(at: sourceURL, to: destURL)
        }
        
        // Restore original attributes
        if let attrs = attributes {
            try? fileManager.setAttributes(attrs, ofItemAtPath: destURL.path)
        }
        
        return destURL
    }
    
    private func convertFile(mediaFile: MediaFileInfo, destinationFolder: URL) throws -> URL {
        switch mediaFile.type {
        case .image:
            return try convertImageToJPEG(sourceURL: mediaFile.url, destinationFolder: destinationFolder)
        case .video:
            return try convertVideoToMP4(sourceURL: mediaFile.url, destinationFolder: destinationFolder)
        }
    }
    
    private func convertImageToJPEG(sourceURL: URL, destinationFolder: URL) throws -> URL {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let destURL = getUniqueDestinationURL(baseName: baseName, extension: "jpg", in: destinationFolder)
        
        guard let sipsPath = findExecutable(paths: ["/usr/bin/sips"]) else {
            throw NSError(domain: "Conversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "sips tool not found"])
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sipsPath)
        process.arguments = [
            "-s", "format", "jpeg",
            "-s", "formatOptions", "85",
            sourceURL.path,
            "--out", destURL.path
        ]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            try? fileManager.removeItem(at: destURL)
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorMsg = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "Conversion", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "sips failed: \(errorMsg)"])
        }
        
        // Verify output
        guard fileManager.fileExists(atPath: destURL.path) else {
            throw NSError(domain: "Conversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Conversion produced no output"])
        }
        
        // Preserve dates
        if let attrs = try? fileManager.attributesOfItem(atPath: sourceURL.path) {
            try? fileManager.setAttributes(attrs, ofItemAtPath: destURL.path)
        }
        
        return destURL
    }
    
    private func convertVideoToMP4(sourceURL: URL, destinationFolder: URL) throws -> URL {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let destURL = getUniqueDestinationURL(baseName: baseName, extension: "mp4", in: destinationFolder)
        
        guard let ffmpegPath = findExecutable(paths: [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]) else {
            // Fallback: just copy without conversion
            appendLog("⚠️ ffmpeg not found, copying without conversion")
            try fileManager.copyItem(at: sourceURL, to: destURL)
            return destURL
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = [
            "-i", sourceURL.path,
            "-c:v", "libx264",
            "-preset", "medium",
            "-crf", "23",
            "-c:a", "aac",
            "-b:a", "128k",
            "-movflags", "+faststart",
            "-y",
            destURL.path
        ]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            try? fileManager.removeItem(at: destURL)
            throw NSError(domain: "Conversion", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "ffmpeg conversion failed"])
        }
        
        guard fileManager.fileExists(atPath: destURL.path) else {
            throw NSError(domain: "Conversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Video conversion produced no output"])
        }
        
        return destURL
    }
    
    // MARK: - Unique File Naming (Thread-Safe, No Placeholders)
    
    private func getUniqueDestinationURL(baseName: String, extension ext: String, in folder: URL) -> URL {
        // Sanitize the base name
        let sanitizedBaseName = sanitizeFileName(baseName)
        
        return modifyStateSync { state -> URL in
            var candidate = folder.appendingPathComponent("\(sanitizedBaseName).\(ext)")
            var index = 1
            
            // Check both filesystem and in-memory reservations
            while self.fileManager.fileExists(atPath: candidate.path) || state.reservedFileNames.contains(candidate.path) {
                candidate = folder.appendingPathComponent("\(sanitizedBaseName)_\(index).\(ext)")
                index += 1
                
                // Safety limit
                if index > 10000 {
                    let uuid = UUID().uuidString.prefix(8)
                    candidate = folder.appendingPathComponent("\(sanitizedBaseName)_\(uuid).\(ext)")
                    break
                }
            }
            
            // Reserve the path
            state.reservedFileNames.insert(candidate.path)
            
            return candidate
        }
    }
    
    private func sanitizeFileName(_ name: String) -> String {
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")
        var sanitized = name.components(separatedBy: invalidChars).joined(separator: "_")
        
        // Limit length
        if sanitized.count > 200 {
            sanitized = String(sanitized.prefix(200))
        }
        
        // Handle empty names
        if sanitized.trimmingCharacters(in: .whitespaces).isEmpty {
            sanitized = "unnamed"
        }
        
        return sanitized
    }
    
    // MARK: - Streaming File Hash
    
    private func calculateFileHashStreaming(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        
        var hasher = SHA256()
        let bufferSize = 1024 * 1024 // 1MB chunks
        
        while autoreleasepool(invoking: {
            guard let data = try? handle.read(upToCount: bufferSize), !data.isEmpty else {
                return false
            }
            hasher.update(data: data)
            return true
        }) {}
        
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    // MARK: - Helper Methods
    
    private func findExecutable(paths: [String]) -> String? {
        paths.first { fileManager.isExecutableFile(atPath: $0) }
    }
    
    private func isRegularFile(url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        return !isDirectory.boolValue
    }
    
    // MARK: - Counter Updates
    
    private func incrementCopied() {
        let count = modifyStateSync { state -> Int in
            state.copiedCount += 1
            return state.copiedCount
        }
        DispatchQueue.main.async { self.totalCopiedSuccessfully = count }
    }
    
    private func incrementConverted() {
        let count = modifyStateSync { state -> Int in
            state.convertedCount += 1
            return state.convertedCount
        }
        DispatchQueue.main.async { self.totalConverted = count }
    }
    
    private func incrementError() {
        let count = modifyStateSync { state -> Int in
            state.errorCount += 1
            return state.errorCount
        }
        DispatchQueue.main.async { self.errorCount = count }
    }
    
    private func incrementSkipped() {
        let count = modifyStateSync { state -> Int in
            state.skippedCount += 1
            return state.skippedCount
        }
        DispatchQueue.main.async { self.totalSkipped = count }
    }
    
    private func updateDuplicatesUI() {
        let count = readState(\.duplicatesCount)
        DispatchQueue.main.async { self.totalSkippedDuplicates = count }
    }
    
    // MARK: - Progress Updates
    
    private func updateProgressEstimates(processed: Int, total: Int) {
        guard let start = startTime, processed > 0 else { return }
        
        let elapsed = Date().timeIntervalSince(start)
        let filesPerSecond = Double(processed) / elapsed
        let remaining = total - processed
        let estimatedSeconds = filesPerSecond > 0 ? Double(remaining) / filesPerSecond : 0
        
        DispatchQueue.main.async {
            self.progress = Double(processed) / Double(total)
            self.processingSpeed = String(format: "%.1f files/sec", filesPerSecond)
            
            if estimatedSeconds < 60 {
                self.estimatedTimeRemaining = String(format: "%.0f sec remaining", estimatedSeconds)
            } else if estimatedSeconds < 3600 {
                self.estimatedTimeRemaining = String(format: "%.1f min remaining", estimatedSeconds / 60)
            } else {
                self.estimatedTimeRemaining = String(format: "%.1f hrs remaining", estimatedSeconds / 3600)
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
        operationQueue = nil
    }
    
    // MARK: - Operation Logging
    
    private func logOperation(source: URL, destination: URL, type: FileOperation.OperationType) {
        let operation = FileOperation(
            sourceURL: source,
            destinationURL: destination,
            operationType: type,
            timestamp: Date()
        )
        
        stateQueue.async(flags: .barrier) {
            self.operationLog.append(operation)
        }
    }
    
    private func saveOperationLog() {
        let operations = stateQueue.sync { self.operationLog }
        guard !operations.isEmpty else { return }
        
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            
            let data = try encoder.encode(operations)
            
            let logsFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
            let timestamp = dateFormatter.string(from: Date())
            let logFile = logsFolder.appendingPathComponent("media_organizer_\(timestamp).json")
            
            try data.write(to: logFile)
            
            DispatchQueue.main.async {
                self.appendLog("📝 Operation log saved: \(logFile.lastPathComponent)")
            }
        } catch {
            DispatchQueue.main.async {
                self.appendLog("⚠️ Could not save operation log: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Cancellation
    
    func cancelOperation() {
        guard isScanning || isProcessing else { return }
        
        modifyState { state in
            state.isCancelled = true
        }
        
        operationQueue?.cancelAllOperations()
        
        appendLog("🛑 Cancellation requested...")
    }
    
    // MARK: - Undo
    
    func undoLastOperation() {
        let operations = stateQueue.sync { self.operationLog }
        
        guard !operations.isEmpty else {
            appendLog("No operations to undo")
            return
        }
        
        guard !isProcessing else {
            appendLog("Cannot undo while processing")
            return
        }
        
        appendLog("⏮️ Starting undo of \(operations.count) operations...")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            
            var successCount = 0
            var failCount = 0
            
            for operation in operations.reversed() {
                do {
                    if self.fileManager.fileExists(atPath: operation.destinationURL.path) {
                        try self.fileManager.removeItem(at: operation.destinationURL)
                        successCount += 1
                    }
                    
                    if operation.operationType == .move {
                        self.appendLog("⚠️ Cannot restore moved file: \(operation.sourceURL.lastPathComponent)")
                    }
                } catch {
                    failCount += 1
                    self.appendLog("❌ Undo failed for \(operation.destinationURL.lastPathComponent)")
                }
            }
            
            self.stateQueue.async(flags: .barrier) {
                self.operationLog = []
            }
            
            DispatchQueue.main.async {
                self.appendLog("✅ Undo complete: \(successCount) removed, \(failCount) failed")
                self.totalCopiedSuccessfully = 0
                self.totalConverted = 0
            }
        }
    }
    
    // MARK: - Logging
    
    func appendLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logEntry = "[\(timestamp)] \(message)"
        
        DispatchQueue.main.async {
            self.logMessages.append(logEntry)
            
            if self.logMessages.count > self.maxLogMessages {
                self.logMessages.removeFirst(self.logMessages.count - self.maxLogMessages)
            }
        }
    }
    
    func clearLogs() {
        logMessages = []
    }
    
    private func statusOnMain(_ status: String) {
        DispatchQueue.main.async {
            self.statusMessage = status
        }
    }
    
    private func showError(_ message: String) {
        DispatchQueue.main.async {
            self.alertMessage = message
            self.showAlert = true
        }
        appendLog("⚠️ \(message)")
    }
    
    // MARK: - Export Logs
    
    func exportLogs() {
        guard !logMessages.isEmpty else {
            showError("No logs to export")
            return
        }
        
        do {
            let logsFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
            let timestamp = dateFormatter.string(from: Date())
            let logFile = logsFolder.appendingPathComponent("media_organizer_logs_\(timestamp).txt")
            
            let logContent = logMessages.joined(separator: "\n")
            try logContent.write(to: logFile, atomically: true, encoding: .utf8)
            
            appendLog("📄 Logs exported: \(logFile.lastPathComponent)")
            
            NSWorkspace.shared.activateFileViewerSelecting([logFile])
        } catch {
            showError("Failed to export logs: \(error.localizedDescription)")
        }
    }
}
