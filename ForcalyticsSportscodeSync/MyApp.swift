
import AppKit
import Combine
import MenuBarExtraAccess
import SwiftUI
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

    private var requestURL: URL?
    private var destinationURL: URL?
    private var securityScopedAccess = false

    func startSync(
        url: URL,
        destination: URL,
        interval: Int
    ) {
        guard !isSyncing else { return }

        requestURL = url
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
                guard let self, isSyncing else { return }

                syncTask = Task { [weak self] in
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
        guard
            isSyncing,
            !isRunningSync,
            let requestURL,
            let destinationURL
        else {
            return
        }

        isRunningSync = true
        defer { isRunningSync = false }

        status = "Fetching data..."

        do {
            var request = URLRequest(url: requestURL)
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

            guard (200 ... 299).contains(httpResponse.statusCode) else {
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
    private var requestURLInput = "https://api.dev.forcalytics.orcalabs.no/v1.0/live_streams/export_sportscode"

    @AppStorage("syncDestinationFolder")
    private var destinationFolderInput = ""

    @AppStorage("syncDestinationFilename")
    private var destinationFilenameInput = "sportscode-sync.json"

    @AppStorage("syncKickoffOffsetSecs")
    private var kickoffOffsetSecsInput = ""

    @AppStorage("syncIntervalSeconds")
    private var syncIntervalSecondsInput = "5"

    @Binding var isMenuPresented: Bool

    private var requestURL: Result<URL, InputError> {
        let input = requestURLInput.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !input.isEmpty else {
            return .failure(.empty)
        }

        guard
            var components = URLComponents(string: input),
            let url = components.url,
            ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
            components.host != nil
        else {
            return .failure(.invalid("Invalid URL"))
        }

        if case let .success(_offset) = kickoffOffsetSecs, let offset = _offset {
            var queryItems = components.queryItems ?? []

            // Replace an existing parameter rather than duplicating it.
            queryItems.removeAll { $0.name == "kickoffOffsetSecs" }

            queryItems.append(
                URLQueryItem(
                    name: "kickoffOffsetSecs",
                    value: String(offset)
                )
            )

            components.queryItems = queryItems

            guard let url = components.url else {
                return .failure(.invalid("Invalid URL and kickoff offset"))
            }

            return .success(url)
        }

        return .success(url)
    }

    private var destinationFolder: Result<URL, InputError> {
        guard !destinationFolderInput.isEmpty else {
            return .failure(.empty)
        }

        return .success(URL(fileURLWithPath: destinationFolderInput))
    }

    private var destinationFilename: Result<String, InputError> {
        guard !destinationFilenameInput.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            return .failure(.empty)
        }

        return .success(destinationFilenameInput)
    }

    private var destinationURL: URL? {
        guard
            case let .success(folder) = destinationFolder,
            case let .success(filename) = destinationFilename
        else {
            return nil
        }

        return folder.appendingPathComponent(filename)
    }

    private var kickoffOffsetSecs: Result<Double?, InputError> {
        let value = kickoffOffsetSecsInput.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !value.isEmpty else {
            return .success(nil)
        }

        guard
            let number = Double(value),
            number.isFinite
        else {
            return .failure(.invalid("Invalid number"))
        }

        guard number >= 0
        else {
            return .failure(.invalid("Must be >= 0"))
        }

        return .success(number)
    }

    private var syncIntervalSeconds: Result<Int, InputError> {
        let value = syncIntervalSecondsInput.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !value.isEmpty else {
            return .failure(.empty)
        }

        guard let number = Int(value) else {
            return .failure(.invalid("Invalid int"))
        }

        guard number >= 1
        else {
            return .failure(.invalid("Must be >= 1"))
        }

        return .success(number)
    }

    private var canStartSync: Bool {
        requestURL.isSuccess && destinationURL != nil && syncIntervalSeconds.isSuccess
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

            Input(
                title: "Requset URL",
                placeholder: "https://example.com/api/data",
                value: $requestURLInput,
                disabled: syncManager.isSyncing,
                error: requestURL.error
            )

            VStack(alignment: .leading, spacing: 6) {
                Text("Destination folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Choose Folder…") {
                    chooseFolder()
                }
                .disabled(syncManager.isSyncing)

                Text(
                    destinationFolderInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "No folder selected"
                        : destinationFolderInput
                )
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
            }

            Input(
                title: "Filename",
                placeholder: "sportscode-sync.json",
                value: $destinationFilenameInput,
                disabled: syncManager.isSyncing,
                error: destinationFilename.error
            )

            Input(
                title: "Kickoff offset (seconds)",
                placeholder: "10",
                value: $kickoffOffsetSecsInput,
                disabled: syncManager.isSyncing,
                error: kickoffOffsetSecs.error
            )

            Input(
                title: "Sync interval (seconds)",
                placeholder: "5",
                value: $syncIntervalSecondsInput,
                disabled: syncManager.isSyncing,
                error: syncIntervalSeconds.error
            )

            Divider()

            Toggle(
                "Enable syncing",
                isOn: Binding(
                    get: { syncManager.isSyncing },
                    set: { enabled in
                        if enabled {
                            guard
                                canStartSync,
                                let destinationURL,
                                case let .success(requestURL) = requestURL,
                                case let .success(syncIntervalSeconds) = syncIntervalSeconds
                            else {
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
            .disabled(!canStartSync)
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
                  let folderURL = panel.url
            else {
                return
            }

            do {
                let bookmark = try folderURL.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )

                DispatchQueue.main.async {
                    destinationFolderInput = folderURL.path

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

enum InputError: Error {
    case empty
    case invalid(String)

    var message: String {
        switch self {
        case .empty:
            "Required"
        case let .invalid(string):
            string
        }
    }
}

struct Input: View {
    let title: String
    let placeholder: String

    @Binding var value: String

    var disabled = false
    var error: InputError?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $value)
                .textFieldStyle(.roundedBorder)
                .disabled(disabled)

            if let error {
                Text(error.message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

extension Result {
    var isSuccess: Bool {
        if case .success = self {
            true
        } else {
            false
        }
    }

    var error: Failure? {
        guard case let .failure(error) = self else {
            return nil
        }
        return error
    }
}
