
import SwiftUI
import AppKit
import Combine
import MenuBarExtraAccess
import UniformTypeIdentifiers


@main
struct MyApp: App {
    @State private var isMenuPresented = false

    var body: some Scene {
        MenuBarExtra(
            "ForcalyticsSportscodeSync",
            systemImage: "arrow.triangle.2.circlepath"
        ) {
            MenuBarView(
                isMenuPresented: $isMenuPresented
            )
        }
        .menuBarExtraAccess(
            isPresented: $isMenuPresented
        ) { _ in }
        .menuBarExtraStyle(.window)
    }
}


@MainActor
final class SyncManager: ObservableObject {
    @Published var isSyncing = false
    @Published var status = "Stopped"
    @Published var lastSync: Date?
    @Published var secondsSinceLastSync = 0

    private var syncTimer: Timer?
    private var elapsedTimer: Timer?
    private var isRunningSync = false
    private var syncTask: Task<Void, Never>?

    private var requestURLString = ""
    private var destinationURL: URL?
    private var securityScopedAccess = false

    func startSync(
        url: String,
        destination: URL,
        interval: Int
    ) {
        guard !isSyncing else { return }

        guard let parsedURL = URL(string: url),
              ["http", "https"].contains(
                  parsedURL.scheme?.lowercased() ?? ""
              ),
              parsedURL.host != nil else {
            status = "Invalid URL"
            return
        }

        guard interval >= 1 else {
            status = "Interval must be at least 1 second"
            return
        }

        requestURLString = url
        destinationURL = destination
        isSyncing = true
        status = "Syncing"

        syncTask = Task { [weak self] in
            await self?.runSync()
        }

        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(interval),
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isSyncing else { return }

                self.syncTask = Task { [weak self] in
                    await self?.runSync()
                }
            }
        }

        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(
            withTimeInterval: 0.5,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateElapsedTime()
            }
        }
    }

    func stopSync() {
        isSyncing = false
        lastSync = nil

        syncTimer?.invalidate()
        syncTimer = nil

        elapsedTimer?.invalidate()
        elapsedTimer = nil

        syncTask?.cancel()
        syncTask = nil
        
        status = "Stopped"
    }

    func setDestinationFolder(_ folderURL: URL) {
        if securityScopedAccess {
            destinationURL?.deletingLastPathComponent()
                .stopAccessingSecurityScopedResource()
        }

        securityScopedAccess =
            folderURL.startAccessingSecurityScopedResource()

        // If access wasn't granted through a security-scoped URL,
        // the app may still be able to access the folder normally.
        destinationURL = folderURL.appendingPathComponent(
            "sportscode-sync.json"
        )
    }

    func setDestinationFilename(_ filename: String) {
        guard let currentURL = destinationURL else { return }

        let cleanedName = filename.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !cleanedName.isEmpty else { return }

        destinationURL = currentURL
            .deletingLastPathComponent()
            .appendingPathComponent(cleanedName)
    }

    private func runSync() async {
        guard isSyncing, !isRunningSync else { return }
        guard let destinationURL else {
            status = "Choose a destination folder"
            return
        }
        guard let url = URL(string: requestURLString) else {
            status = "Invalid URL"
            return
        }

        isRunningSync = true
        defer { isRunningSync = false }

        status = "Fetching data..."

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 30
            request.cachePolicy = .reloadIgnoringLocalCacheData

            let (data, response) = try await URLSession.shared.data(
                for: request
            )

            try Task.checkCancellation()
            guard isSyncing else { return }

            guard let httpResponse = response as? HTTPURLResponse else {
                status = "Invalid server response"
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                status = "HTTP error: \(httpResponse.statusCode)"
                return
            }

            // Create the parent folder if it doesn't exist.
            let folderURL = destinationURL.deletingLastPathComponent()

            try FileManager.default.createDirectory(
                at: folderURL,
                withIntermediateDirectories: true
            )

            let fileManager = FileManager.default

            if fileManager.fileExists(atPath: destinationURL.path) {
                let existingData = try Data(contentsOf: destinationURL)
                
                if existingData == data {
                    print("GET successful. No changes detected.")
                } else {
                    try data.write(to: destinationURL, options: .atomic)
                    print("GET successful. File updated.")
                }
            } else {
                try data.write(to: destinationURL, options: .atomic)
                print("GET successful. File created.")
            }

            lastSync = Date()
            secondsSinceLastSync = 0
            status = "Sync successful"

        } catch is CancellationError {
            // Expected when stopping sync.
        } catch {
            guard isSyncing else { return }
            status = "Error: \(error.localizedDescription)"
            print("Sync failed: \(error)")
        }
    }

    private func updateElapsedTime() {
        guard let lastSync else { return }

        secondsSinceLastSync = max(
            0,
            Int(Date().timeIntervalSince(lastSync))
        )
    }
}


struct MenuBarView: View {
    @StateObject private var syncManager = SyncManager()

    @AppStorage("syncRequestURL")
    private var requestURL = "https://api.dev.forcalytics.orcalabs.no/v1.0/live_streams/export_sportscode"

    @AppStorage("syncDestinationFolder")
    private var destinationFolder = ""

    @AppStorage("syncDestinationFilename")
    private var destinationFilename = "sportscode-sync.json"
    
    @AppStorage("syncIntervalSeconds")
    private var syncIntervalSeconds = 5
    
    @Binding var isMenuPresented: Bool
    
    private var destinationURL: URL? {
        guard !destinationFolder.isEmpty,
              !destinationFilename.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: destinationFolder)
            .appendingPathComponent(destinationFilename)
    }

    private var canStartSync: Bool {
        guard let url = URL(string: requestURL),
              ["http", "https"].contains(
                url.scheme?.lowercased() ?? ""
              ),
              url.host != nil,
              destinationURL != nil else {
            return false
        }

        return true
    }

    private var elapsedText: String {
        let seconds = syncManager.secondsSinceLastSync
        return "\(seconds) second\(seconds == 1 ? "" : "s") ago"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.title2)

                Text("Forcalytics Sportscode Sync")
                    .font(.headline)

                Spacer()

                Circle()
                    .fill(syncManager.isSyncing ? .green : .gray)
                    .frame(width: 9, height: 9)
            }

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Text("Request URL")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField(
                    "https://example.com/api/data",
                    text: $requestURL
                )
                .textFieldStyle(.roundedBorder)
                .disabled(syncManager.isSyncing)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Destination folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Choose Folder…") {
                    chooseFolder()
                }
                .disabled(syncManager.isSyncing)

                Text(
                    destinationFolder.isEmpty
                        ? "No folder selected"
                        : destinationFolder
                )
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Filename")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField(
                    "sportscode-sync.json",
                    text: $destinationFilename
                )
                .textFieldStyle(.roundedBorder)
                .disabled(syncManager.isSyncing)
            }
            
            VStack(alignment: .leading, spacing: 5) {
                Text("Sync interval (seconds)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    TextField(
                        "5",
                        value: $syncIntervalSeconds,
                        format: .number
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .disabled(syncManager.isSyncing)
                }
            }

            Divider()

            Toggle(
                "Enable syncing",
                isOn: Binding(
                    get: { syncManager.isSyncing },
                    set: { enabled in
                        if enabled {
                            guard canStartSync,
                                  let destinationURL else {
                                syncManager.status =
                                    "Set URL and choose a folder"
                                return
                            }

                            syncManager.startSync(
                                url: requestURL,
                                destination: destinationURL,
                                interval: syncIntervalSeconds
                            )
                        } else {
                            syncManager.stopSync()
                        }
                    }
                )
            )
            .toggleStyle(.switch)

            HStack(alignment: .top) {
                Text("Status")
                    .foregroundStyle(.secondary)

                Spacer()

                Text(syncManager.status)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            .font(.caption)

            HStack {
                Text("Last sync")
                    .foregroundStyle(.secondary)

                Spacer()

                Text(
                    syncManager.lastSync == nil
                        ? ""
                        : elapsedText
                )
                .monospacedDigit()
            }
            .font(.caption)

            Divider()

            Button("Quit") {
                syncManager.stopSync()
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding()
        .frame(width: 340)
    }
    
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.prompt = "Choose"
        panel.title = "Choose Sync Destination"
        panel.message = "Select the folder where sync data will be saved."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        panel.begin { response in
            guard response == .OK,
                  let folderURL = panel.url else {
                return
            }

            do {
                let bookmark = try folderURL.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )

                DispatchQueue.main.async {
                    destinationFolder = folderURL.path

                    UserDefaults.standard.set(
                        bookmark,
                        forKey: "syncDestinationBookmark"
                    )

                    syncManager.setDestinationFolder(folderURL)

                    // Reopen the menu bar popover after selection.
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + 0.3
                    ) {
                        isMenuPresented = true
                    }
                }
            } catch {
                print("Failed to save folder permission: \(error)")
            }
        }
    }
}
