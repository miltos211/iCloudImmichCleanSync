# iCloudImmichCleanSync

A macOS app to automatically sync your entire iCloud Photo Library to Immich with full quality and metadata preservation.

## Why This Exists

I needed a reliable way to back up my 3,000+ photos and videos from iCloud to my Immich server as a secondary backup. The Immich mobile app seemed like the obvious choice, but iOS's aggressive background task restrictions kept stalling uploads. After days of frustration watching sync progress randomly pause and restart, I realized I needed a different approach.

So I built this tool. It's macOS-only, but that's actually the key - running on your Mac means no iOS background restrictions, direct PhotoKit access, and reliable, uninterrupted uploads.

The project started as a Python CLI tool, but I wanted to try Swift, so I eventually rewrote it as a native Swift app. Both implementations exist in this repository and can be used independently.

## Features

- **Native macOS Integration**: Uses PhotoKit to access your full iCloud Photo Library directly - no iOS background task limitations
- **True High-Quality Assets**: Downloads and uploads original full-resolution files, not compressed versions
- **Complete Metadata Preservation**: Keeps all embedded EXIF data including GPS coordinates, camera make/model, lens info, and timestamps
- **Smart Duplicate Detection**: Checks what's already on your Immich server before uploading to avoid wasting time and bandwidth
- **Flexible Sync Options**:
  - Toggle photos on/off
  - Toggle videos on/off
  - Toggle screenshots separately
  - Live Photos supported (uploads the .HEIC image)
- **Clean SwiftUI Interface**: Real-time progress tracking, detailed logs, and a dashboard showing what's been synced
- **Battle-Tested**: Successfully handles libraries with 30,000+ assets

## How It Works

The app uses a Swift binary (`photo-exporter`) that interfaces with macOS PhotoKit to list and export photos. This ensures you get:

- Full-resolution originals (not iCloud's "optimized" versions)
- All metadata intact
- Proper handling of Live Photos, bursts, and screenshots
- Reliable exports without iOS restrictions

The SwiftUI app provides a user-friendly interface and manages the upload process to your Immich server with progress tracking and error handling.

### Python Implementation

The Python implementation (`python/photo-sync.py`) is a CLI orchestrator that:

- Calls the Swift CLI binary to access PhotoKit (required for iCloud Photo Library access)
- Manages sync state in a local SQLite database
- Handles uploads to Immich with retry logic and exponential backoff
- Provides a rich terminal UI with progress bars and statistics
- Supports resumable syncs - stop and restart without losing progress

This is useful if you prefer CLI tools, want to run syncs via cron/scripts, or need more control over the sync process.

## Requirements

- macOS 14+
- Xcode / Swift toolchain (for building)
- Python 3.9+ (only if using the Python implementation)

## Project Structure

```
/
├── Sources/                  # Swift implementation
│   ├── App/                  # SwiftUI macOS app
│   ├── CLI/                  # Swift CLI tool (photo-exporter)
│   └── Shared/               # Shared library (PhotoKit, models)
├── python/                   # Python implementation
│   ├── photo-sync.py         # Main sync script
│   ├── requirements.txt      # Python dependencies
│   └── lib/                  # Helper modules
├── tests/
│   └── swift/                # Integration tests for Swift CLI
├── config.cfg                # Configuration file
└── Package.swift             # Swift package manifest
```

## Building

### Swift App

Build and run the SwiftUI app:

```bash
swift build -c release
swift run ImmichUploader
```

### Swift CLI

Build the CLI tool (required for Python implementation):

```bash
swift build -c release
cp .build/release/photo-exporter python/lib/
```

The CLI provides two commands:

```bash
# List all assets in Photo Library
./python/lib/photo-exporter list-assets --type all

# Export a specific asset
./python/lib/photo-exporter export-asset <asset-id> <output-directory>
```

### Python

Set up the Python environment:

```bash
cd python
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Before running, ensure the Swift CLI is built (see above).

## Configuration

Copy `.env.template` to `.env` and add your Immich server URL and API key.

## Usage

### Swift App

Run the app and configure your Immich server connection in Settings. Select which media types to sync and start the sync process.

### Python CLI

```bash
cd python
source .venv/bin/activate
python photo-sync.py
```

## Running Tests

```bash
cd tests/swift
python -m pytest test_swift.py -v
```
