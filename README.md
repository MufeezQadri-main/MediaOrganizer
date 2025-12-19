# 📁 

A native macOS application built with SwiftUI that helps you organize your media files by scanning folders recursively and moving photos and videos to a destination folder of your choice.

## ✨ Features

- **📂 Folder Selection**: Easy-to-use macOS file picker for selecting source and destination folders
- **🔍 Recursive Scanning**: Automatically scans all nested subfolders to find media files
- **🖼️ Media Detection**: Identifies photos and videos by file extension (case-insensitive)
  - **Images**: `.jpg`, `.jpeg`, `.png`, `.heic`, `.gif`, `.bmp`, `.tiff`, `.webp`
  - **Videos**: `.mp4`, `.mov`, `.mkv`, `.avi`, `.flv`, `.wmv`, `.webm`
- **🔄 Image Conversion**: Convert images to different formats (JPEG, PNG, TIFF, BMP) using macOS built-in tools
- **🛡️ Safe Moving**: Automatically renames files on conflicts (e.g., `photo_1.jpg`, `photo_2.jpg`)
- **📊 Metadata Preservation**: Preserves file creation and modification dates
- **📈 Progress Tracking**: Real-time progress bar and detailed statistics
- **📝 Detailed Logging**: Comprehensive log of all operations with timestamps
- **⚡ Non-Blocking UI**: All operations run on background threads to keep the UI responsive

## 📋 Requirements

- macOS 12.0 (Monterey) or later
- Xcode 13.0 or later (for building from source)

## 🚀 Installation

### Option 1: Download Pre-built App (Coming Soon)

1. Download the latest release from the MufeezQadri-main/Media Organizer page
2. Extract the ZIP file or open the DMG
3. Drag `MediaOrganizer.app` to your Applications folder
4. Open the app (you may need to right-click and select "Open" the first time)

### Option 2: Build from Source

1. Clone this repository:
   ```bash
   git clone https://github.com/yourusername/media-organizer.git
   cd media-organizer
   ```

2. Open the project in Xcode:
   ```bash
   open MediaOrganizer.xcodeproj
   ```

3. Build and run:
   - Press `⌘R` or click the Run button
   - Or build only: Press `⌘B`

## 📖 Usage

1. **Launch the app** from your Applications folder
2. **Select Source Folder**: Click "Select Source Folder" and choose the folder containing your media files
3. **Select Destination Folder**: Click "Select Destination Folder" and choose where you want the media files moved
4. **Optional - Enable Image Conversion**: 
   - Toggle "Convert Images" if you want to convert images to a different format
   - Select the target format (JPEG, PNG, TIFF, or BMP)
5. **Start Processing**: Click "Start Scan & Move" to begin
6. **Monitor Progress**: Watch the progress bar and logs to track the operation

### First-Time Security Warning

If macOS shows a security warning:
1. Right-click `MediaOrganizer.app`
2. Select **"Open"**
3. Click **"Open"** in the security dialog
4. This is a one-time requirement

## 🏗️ Project Structure

```
MediaOrganizer/
├── MediaOrganizerApp.swift      # SwiftUI app entry point
├── ContentView.swift             # Main UI view
├── MediaOrganizerViewModel.swift # Business logic, scanning, and file operations
└── README.md                     # This file
```

## 🔧 Development

### Setting Up the Project

1. Create a new macOS App project in Xcode:
   - **File → New → Project**
   - Choose **macOS → App**
   - Use **SwiftUI** for interface
   - Name it `MediaOrganizer`

2. Add the source files to your project:
   - Copy `MediaOrganizerApp.swift`, `ContentView.swift`, and `MediaOrganizerViewModel.swift` to your project
   - Ensure all files are added to the app target

3. Configure App Sandbox:
   - Select your app target
   - Go to **Signing & Capabilities**
   - Enable **App Sandbox**
   - Under **File Access**, set **User Selected File** to **Read/Write**

### Building for Distribution

See [PACKAGING_INSTRUCTIONS.md](PACKAGING_INSTRUCTIONS.md) for detailed instructions on creating distributable packages.

## 🛠️ Technical Details

- **Framework**: SwiftUI + AppKit
- **Language**: Swift 5.0+
- **Image Conversion**: Uses macOS built-in `sips` command-line tool
- **File Operations**: Native `FileManager` APIs with security-scoped resource access
- **Architecture**: MVVM (Model-View-ViewModel)
- **Concurrency**: Background queues with main thread UI updates

## 📝 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## 🐛 Known Issues

- None at the moment! If you find any, please [open an issue](https://github.com/yourusername/media-organizer/issues).

## 🔮 Future Enhancements

- [ ] Support for more image formats
- [ ] Batch renaming options
- [ ] Duplicate file detection
- [ ] Preview of files before moving
- [ ] Undo functionality
- [ ] Custom file organization rules

## 📧 Support

If you encounter any issues or have questions:
- [Open an issue](https://github.com/yourusername/media-organizer/issues) on GitHub
- Check the [Documentation](https://github.com/yourusername/media-organizer/wiki)

## 🙏 Acknowledgments

- Built with SwiftUI and native macOS APIs
- Uses macOS built-in `sips` for image conversion

## ⚠️ Disclaimer

This app moves files from one location to another. Always:
- Test with a small folder first
- Keep backups of important files
- Review the destination folder before processing large batches

---

**Made with ❤️ for macOS**
