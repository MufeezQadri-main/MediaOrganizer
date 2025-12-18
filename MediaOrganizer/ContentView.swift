import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = MediaOrganizerViewModel()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Media File Organizer")
                .font(.largeTitle)
                .fontWeight(.semibold)
            
            Text("Select a source folder to scan for photos and videos, then choose a destination folder where all detected media will be moved.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Divider()
            
            // Folder selection
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Source Folder")
                        .font(.headline)
                    Text(viewModel.sourceURL?.path ?? "No folder selected")
                        .font(.caption)
                        .foregroundColor(viewModel.sourceURL == nil ? .secondary : .primary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Select Source Folder") {
                    viewModel.pickSourceFolder()
                }
                .disabled(viewModel.isRunning)
            }
            
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Destination Folder")
                        .font(.headline)
                    Text(viewModel.destinationURL?.path ?? "No folder selected")
                        .font(.caption)
                        .foregroundColor(viewModel.destinationURL == nil ? .secondary : .primary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Select Destination Folder") {
                    viewModel.pickDestinationFolder()
                }
                .disabled(viewModel.isRunning)
            }
            
            Divider()
            
            // Image conversion settings
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Convert Images", isOn: $viewModel.convertImages)
                    .font(.headline)
                    .disabled(viewModel.isRunning)
                
                if viewModel.convertImages {
                    HStack {
                        Text("Target Format:")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        Picker("", selection: $viewModel.targetImageFormat) {
                            ForEach(MediaOrganizerViewModel.ImageFormat.allCases, id: \.self) { format in
                                Text(format.displayName).tag(format)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(viewModel.isRunning)
                    }
                    .padding(.leading, 20)
                }
            }
            .padding(.vertical, 4)
            
            Divider()
            
            // Stats & actions
            HStack(spacing: 24) {
                VStack(alignment: .leading) {
                    Text("Total Files Scanned")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(viewModel.totalFilesScanned)")
                        .font(.headline)
                }
                
                VStack(alignment: .leading) {
                    Text("Media Files Found")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(viewModel.totalMediaFound)")
                        .font(.headline)
                }
                
                VStack(alignment: .leading) {
                    Text("Files Moved")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(viewModel.totalMovedSuccessfully)")
                        .font(.headline)
                }
                
                if viewModel.convertImages && viewModel.totalConverted > 0 {
                    VStack(alignment: .leading) {
                        Text("Images Converted")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(viewModel.totalConverted)")
                            .font(.headline)
                            .foregroundColor(.blue)
                    }
                }
                
                Spacer()
                
                Button(action: {
                    viewModel.startScanAndMove()
                }) {
                    HStack {
                        if viewModel.isRunning {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                        Text("Start Scan & Move")
                            .fontWeight(.semibold)
                    }
                }
                .disabled(viewModel.isRunning || viewModel.sourceURL == nil || viewModel.destinationURL == nil)
            }
            
            if let progress = viewModel.progress {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress)
                    Text("Progress: \(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // Status & logs
            VStack(alignment: .leading, spacing: 4) {
                Text("Status: \(viewModel.statusMessage)")
                    .font(.subheadline)
                
                Text("Logs")
                    .font(.headline)
                    .padding(.top, 4)
                
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(viewModel.logMessages.enumerated()), id: \.offset) { _, message in
                            Text(message)
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(6)
                }
                .frame(minHeight: 160, maxHeight: 260)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.3))
                )
            }
            
            Spacer()
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 520)
    }
}

#Preview {
    ContentView()
}


