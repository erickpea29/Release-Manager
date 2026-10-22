import GitHubIntegration
import RelvoraCore
import SwiftUI

/// A project's GitHub repositories: connect, browse cached data, refresh.
struct RepositoriesView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: WorkspaceModel
    @State private var selection: UUID?
    @State private var isPicking = false
    @State private var isShowingConnect = false
    @State private var pendingDisconnect: RepositoryConnection?

    private var github: GitHubModel { app.github }

    var body: some View {
        Group {
            if github.status == .unavailable {
                ContentUnavailableView(
                    "GitHub Unavailable", systemImage: "exclamationmark.triangle",
                    description: Text("This build has no GitHub App configured."))
            } else if model.connections.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    repositoryList
                    Divider()
                    if let connection = model.connections.first(where: { $0.id == selection }) {
                        RepositoryDetailView(connection: connection, model: model)
                            .id(connection.id)
                    } else {
                        ContentUnavailableView("Select a Repository", systemImage: "folder")
                    }
                }
            }
        }
        .onAppear { selection = selection ?? model.connections.first?.id }
        .onChange(of: model.connections) { if !$1.contains(where: { $0.id == selection }) { selection = $1.first?.id } }
        .sheet(isPresented: $isPicking) {
            RepositoryPickerSheet(model: model) { selection = $0.id }
        }
        .sheet(isPresented: $isShowingConnect) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text("Connect GitHub").font(.title2.bold())
                GitHubConnectionPanel()
                HStack {
                    Spacer()
                    Button("Done") { isShowingConnect = false }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(Spacing.l)
            .frame(width: 460)
        }
        .confirmationDialog(
            "Disconnect \(pendingDisconnect?.fullName ?? "")?",
            isPresented: Binding(get: { pendingDisconnect != nil }, set: { if !$0 { pendingDisconnect = nil } }),
            titleVisibility: .visible, presenting: pendingDisconnect
        ) { connection in
            Button("Disconnect Repository", role: .destructive) { Task { await model.disconnect(connection) } }
        } message: { _ in
            Text("The repository stays on GitHub. You can connect it again at any time.")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if github.isConnected {
            ContentUnavailableView {
                Label("No Repositories", systemImage: "folder.badge.plus")
            } description: {
                Text("Connect the GitHub repositories this project releases from.")
            } actions: {
                Button("Connect Repository…") { isPicking = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text("GitHub").font(.title2.bold())
                GitHubConnectionPanel()
            }
            .frame(maxWidth: 460)
            .panel(padding: Spacing.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var repositoryList: some View {
        List(selection: $selection) {
            ForEach(model.connections) { connection in
                VStack(alignment: .leading, spacing: 2) {
                    Label(connection.name, systemImage: connection.isPrivate ? "lock" : "book.closed")
                    Text(connection.owner)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(connection.id)
                .contextMenu {
                    Link("Open on GitHub", destination: connection.htmlURL)
                    Divider()
                    Button("Disconnect Repository…", role: .destructive) { pendingDisconnect = connection }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                if !github.isConnected {
                    Button("Connect GitHub…", systemImage: "exclamationmark.triangle") { isShowingConnect = true }
                        .foregroundStyle(.orange)
                }
                Button("Connect Repository…", systemImage: "plus") { isPicking = true }
                    .disabled(!github.isConnected)
            }
            .buttonStyle(.borderless)
            .padding(Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Fixed width applied after the inset: the inset's flexible width would otherwise make the whole column
        // share space with the detail view.
        .frame(width: 230)
    }
}

struct RepositoryPickerSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let model: WorkspaceModel
    let onConnected: (RepositoryConnection) -> Void

    @State private var repositories: [GitHubRepository] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var query = ""
    @State private var selection: Int64?
    @State private var isConnecting = false

    private var connectedIDs: Set<Int64> { Set(model.connections.map(\.githubRepositoryID)) }
    private var filtered: [GitHubRepository] {
        repositories.filter { TextSearch.matches(query, fields: [$0.fullName, $0.description]) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Connect a Repository").font(.title2.bold())
            TextField("Search repositories", text: $query)
                .textFieldStyle(.roundedBorder)
            Group {
                if isLoading {
                    ProgressView("Loading repositories…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if repositories.isEmpty && errorMessage == nil {
                    ContentUnavailableView(
                        "No Repositories", systemImage: "folder",
                        description: Text("The Relvora app isn’t installed on any repository yet."))
                } else {
                    List(filtered, selection: $selection) { repository in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Label(repository.fullName, systemImage: repository.isPrivate ? "lock" : "book.closed")
                                if let description = repository.description, !description.isEmpty {
                                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            if connectedIDs.contains(repository.id) {
                                Text("Connected").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(repository.id)
                    }
                    .listStyle(.bordered)
                }
            }
            .frame(height: 300)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if let url = app.github.configuration?.installURL {
                    Link("Add repositories on GitHub…", destination: url).font(.callout)
                }
                Button("Reload") { Task { await load() } }
                    .buttonStyle(.borderless)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { Task { await connect() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil || selection.map(connectedIDs.contains) == true || isConnecting)
            }
        }
        .padding(Spacing.l)
        .frame(width: 520)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            repositories = try await app.github.installationRepositories()
        } catch {
            errorMessage = AppAlert.message(for: error)
        }
    }

    private func connect() async {
        guard let repository = repositories.first(where: { $0.id == selection }) else { return }
        isConnecting = true
        defer { isConnecting = false }
        do {
            onConnected(try await model.connect(repository))
            dismiss()
        } catch {
            errorMessage = AppAlert.message(for: error)
        }
    }
}
