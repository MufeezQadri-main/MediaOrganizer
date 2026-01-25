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
                                action: { viewModel.pickSourceFolder() }
                            )
                            
                            MinimalFolderCard(
                                title: "Destination",
                                subtitle: "Target",
                                selectedPath: viewModel.destinationURL?.lastPathComponent,
                                action: { viewModel.pickDestinationFolder() }
                            )
                        }
                        
                        // Settings
                        VStack(spacing: 4) {
                            MinimalToggle(title: "Copy", isOn: $viewModel.shouldCopyInsteadOfMove)
                            MinimalToggle(title: "Convert", isOn: $viewModel.convertToIOSFormat)
                            MinimalToggle(title: "Skip dupes", isOn: $viewModel.skipDuplicates)
                            MinimalToggle(title: "Dry run", isOn: $viewModel.isDryRun)
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
                            .disabled(viewModel.isScanning || viewModel.isProcessing || viewModel.sourceURL == nil)
                            .opacity(viewModel.sourceURL != nil ? 1 : 0.5)
                            
                            Button(action: { viewModel.startProcessing() }) {
                                Text("Process")
                                    .font(.system(size: 11, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 28)
                                    .foregroundColor(.white)
                                    .background(Color.black)
                                    .cornerRadius(6)
                            }
                            .disabled(!viewModel.scanComplete || viewModel.isProcessing)
                            .opacity(viewModel.scanComplete && !viewModel.isProcessing ? 1 : 0.5)
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
                                
                                if let fileName = viewModel.currentFileName {
                                    Text(fileName)
                                        .font(.system(size: 8, weight: .regular, design: .monospaced))
                                        .foregroundColor(.gray.opacity(0.7))
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
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
                            MinimalStatRow(label: "Processed", value: viewModel.totalCopiedSuccessfully)
                            MinimalStatRow(label: "Converted", value: viewModel.totalConverted)
                            MinimalStatRow(label: "Duplicates", value: viewModel.totalSkippedDuplicates)
                            MinimalStatRow(label: "Errors", value: viewModel.errorCount, isError: true)
                        }
                        
                        // Bottom actions
                        HStack(spacing: 6) {
                            Button(action: { viewModel.undoLastOperation() }) {
                                Text("Undo")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(.gray)
                            }
                            
                            Button(action: { try? viewModel.exportLogs() }) {
                                Text("Logs")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(.gray)
                            }
                            
                            Spacer()
                        }
                        
                        // Log
                        if !viewModel.logMessages.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Log")
                                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.gray)
                                
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 0) {
                                        ForEach(viewModel.logMessages.suffix(8), id: \.self) { log in
                                            Text(log)
                                                .font(.system(size: 7, weight: .regular, design: .monospaced))
                                                .foregroundColor(.gray.opacity(0.6))
                                                .lineLimit(1)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(height: 80)
                            }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 500)
    }
}

struct MinimalFolderCard: View {
    let title: String
    let subtitle: String
    let selectedPath: String?
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
                Text(selectedPath ?? "Choose")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(selectedPath != nil ? .gray : .gray.opacity(0.5))
                    .lineLimit(1)
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

#Preview {
    ContentView()
}
