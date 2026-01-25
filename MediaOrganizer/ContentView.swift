import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = MediaOrganizerViewModel()
    
    var body: some View {
        ZStack {
            Color(red: 0.98, green: 0.98, blue: 0.99)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Minimal header
                VStack(alignment: .leading, spacing: 1) {
                    Text("Media Organizer")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Organize media")
                        .font(.system(size: 9, weight: .light))
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white)
                .overlay(Rectangle().frame(height: 1).foregroundColor(.gray.opacity(0.1)), alignment: .bottom)
                
                // Main content
                ScrollView {
                    VStack(spacing: 10) {
                        // Folder selection
                        VStack(spacing: 6) {
                            MinimalFolderCard(
                                title: "Source",
                                subtitle: "Scan",
                                selectedPath: viewModel.sourceURL?.lastPathComponent,
                                fullPath: viewModel.sourceURL?.path,
                                action: { viewModel.pickSourceFolder() }
                            )
                            
                            MinimalFolderCard(
                                title: "Destination",
                                subtitle: "Target",
                                selectedPath: viewModel.destinationURL?.lastPathComponent,
                                fullPath: viewModel.destinationURL?.path,
                                action: { viewModel.pickDestinationFolder() }
                            )
                        }
                        
                        // Validation warning
                        if let warning = viewModel.validationWarning {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 10))
                                Text(warning)
                                    .font(.system(size: 9, weight: .medium))
                            }
                            .foregroundColor(.orange)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(6)
                        }
                        
                        // Settings
                        VStack(spacing: 4) {
                            MinimalToggle(title: "Copy (uncheck to move)", isOn: $viewModel.shouldCopyInsteadOfMove)
                            MinimalToggle(title: "Convert to iOS formats", isOn: $viewModel.convertToIOSFormat)
                            MinimalToggle(title: "Skip duplicates", isOn: $viewModel.skipDuplicates)
                            MinimalToggle(title: "Dry run (no changes)", isOn: $viewModel.isDryRun)
                        }
                        
                        // Action buttons
                        HStack(spacing: 6) {
                            Button(action: { viewModel.startScan() }) {
                                Text("Scan")
                                    .font(.system(size: 11, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 28)
                                    .foregroundColor(.white)
                                    .background(Color.black)
                                    .cornerRadius(6)
                            }
                            .disabled(viewModel.isScanDisabled)
                            .opacity(viewModel.isScanDisabled ? 0.5 : 1)
                            
                            Button(action: { viewModel.startProcessing() }) {
                                Text("Process")
                                    .font(.system(size: 11, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 28)
                                    .foregroundColor(.white)
                                    .background(Color.black)
                                    .cornerRadius(6)
                            }
                            .disabled(viewModel.isProcessDisabled)
                            .opacity(viewModel.isProcessDisabled ? 0.5 : 1)
                            
                            // Cancel button - shown during operations
                            if viewModel.isScanning || viewModel.isProcessing {
                                Button(action: { viewModel.cancelOperation() }) {
                                    Text("Cancel")
                                        .font(.system(size: 11, weight: .semibold))
                                        .frame(width: 60)
                                        .frame(height: 28)
                                        .foregroundColor(.white)
                                        .background(Color.red.opacity(0.8))
                                        .cornerRadius(6)
                                }
                            }
                        }
                        
                        // Progress
                        if viewModel.isScanning || viewModel.isProcessing {
                            VStack(spacing: 6) {
                                HStack {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                    Text(viewModel.statusMessage)
                                        .font(.system(size: 9, weight: .regular))
                                        .foregroundColor(.gray)
                                    Spacer()
                                    
                                    if let timeRemaining = viewModel.estimatedTimeRemaining {
                                        Text(timeRemaining)
                                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                                            .foregroundColor(.gray)
                                    }
                                }
                                
                                if let progress = viewModel.progress {
                                    HStack(spacing: 4) {
                                        ProgressView(value: progress)
                                            .tint(.black)
                                        Text("\(Int(progress * 100))%")
                                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                            .foregroundColor(.gray)
                                            .frame(width: 28)
                                    }
                                }
                                
                                HStack {
                                    if let fileName = viewModel.currentFileName {
                                        Text(fileName)
                                            .font(.system(size: 8, weight: .regular, design: .monospaced))
                                            .foregroundColor(.gray.opacity(0.7))
                                            .lineLimit(1)
                                    }
                                    
                                    Spacer()
                                    
                                    if let speed = viewModel.processingSpeed {
                                        Text(speed)
                                            .font(.system(size: 8, weight: .regular, design: .monospaced))
                                            .foregroundColor(.gray.opacity(0.7))
                                    }
                                }
                            }
                            .padding(8)
                            .background(Color.gray.opacity(0.05))
                            .cornerRadius(6)
                        }
                        
                        // Stats
                        VStack(spacing: 4) {
                            MinimalStatRow(label: "Scanned", value: viewModel.totalFilesScanned)
                            MinimalStatRow(label: "Found", value: viewModel.totalMediaFound)
                            MinimalStatRowText(label: "Total Size", value: viewModel.totalSizeFormatted)
                            MinimalStatRow(label: "Processed", value: viewModel.totalCopiedSuccessfully)
                            MinimalStatRow(label: "Converted", value: viewModel.totalConverted)
                            MinimalStatRow(label: "Duplicates", value: viewModel.totalSkippedDuplicates)
                            MinimalStatRow(label: "Skipped", value: viewModel.totalSkipped)
                            MinimalStatRow(label: "Errors", value: viewModel.errorCount, isError: true)
                            
                            if let diskSpace = viewModel.availableDiskSpace {
                                MinimalStatRowText(label: "Disk Space", value: diskSpace)
                            }
                        }
                        
                        // Bottom actions
                        HStack(spacing: 6) {
                            Button(action: { viewModel.undoLastOperation() }) {
                                Text("Undo")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(viewModel.canUndo ? .gray : .gray.opacity(0.4))
                            }
                            .disabled(!viewModel.canUndo)
                            
                            Button(action: { viewModel.exportLogs() }) {
                                Text("Logs")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(.gray)
                            }
                            
                            Button(action: { viewModel.clearLogs() }) {
                                Text("Clear")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(.gray)
                            }
                            
                            Spacer()
                        }
                        
                        // Log
                        if !viewModel.logMessages.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Log (\(viewModel.logMessages.count))")
                                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                        .foregroundColor(.gray)
                                    Spacer()
                                }
                                
                                ScrollViewReader { proxy in
                                    ScrollView {
                                        VStack(alignment: .leading, spacing: 2) {
                                            ForEach(Array(viewModel.logMessages.suffix(50).enumerated()), id: \.offset) { index, log in
                                                Text(log)
                                                    .font(.system(size: 7, weight: .regular, design: .monospaced))
                                                    .foregroundColor(log.contains("❌") ? .red.opacity(0.8) : .gray.opacity(0.6))
                                                    .lineLimit(2)
                                                    .id(index)
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .frame(height: 100)
                                }
                            }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 600)
        .alert("Error", isPresented: $viewModel.showAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.alertMessage ?? "An unknown error occurred")
        }
    }
}

// MARK: - Subviews

struct MinimalFolderCard: View {
    let title: String
    let subtitle: String
    let selectedPath: String?
    let fullPath: String?
    let action: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 8, weight: .light))
                        .foregroundColor(.gray)
                }
                Spacer()
            }
            
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(selectedPath ?? "Choose folder...")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(selectedPath != nil ? .primary : .gray.opacity(0.5))
                        .lineLimit(1)
                    
                    if let fullPath = fullPath {
                        Text(fullPath)
                            .font(.system(size: 7, design: .monospaced))
                            .foregroundColor(.gray.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                Button(action: action) {
                    Text("Select")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.8))
                        .cornerRadius(4)
                }
            }
        }
        .padding(8)
        .background(Color.white)
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.1), lineWidth: 0.5))
    }
}

struct MinimalToggle: View {
    let title: String
    @Binding var isOn: Bool
    
    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .regular))
            Spacer()
            Toggle("", isOn: $isOn)
                .tint(.black)
                .scaleEffect(0.75, anchor: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white)
        .cornerRadius(6)
    }
}

struct MinimalStatRow: View {
    let label: String
    let value: Int
    var isError: Bool = false
    
    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 9, weight: .light))
                .foregroundColor(.gray)
            Spacer()
            Text("\(value)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(isError && value > 0 ? .red : .black)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white)
        .cornerRadius(6)
    }
}

struct MinimalStatRowText: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 9, weight: .light))
                .foregroundColor(.gray)
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.black)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white)
        .cornerRadius(6)
    }
}

#Preview {
    ContentView()
}
