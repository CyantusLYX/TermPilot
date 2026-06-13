import SwiftData
import SwiftUI
import TipKit

struct VaultsFlowView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncUnlockStore.self) private var syncUnlockStore
    @Environment(SecureSecretStore.self) private var secureSecretStore
    @Query(sort: \VaultProfile.createdAt) private var vaults: [VaultProfile]
    @Query(sort: \HostProfile.alias) private var hosts: [HostProfile]
    @Query(sort: \KeychainItemProfile.name) private var keychainItems: [KeychainItemProfile]
    @Query(sort: \SnippetProfile.title) private var snippets: [SnippetProfile]

    @State private var isAddingVault = false
    @State private var searchText = ""
    @AppStorage("vaultsSortOption") private var sortOptionRawValue = VaultSortOption.name.rawValue

    private var sortOption: VaultSortOption {
        SortOptionStorage.value(from: sortOptionRawValue, default: .name)
    }

    private var searchedVaults: [VaultProfile] {
        let filteredVaults = vaults.filter { vault in
            ProfileSearch.matches(searchText, fields: [
                vault.name,
                "\(hosts.filter { $0.vaultID == vault.id }.count) hosts",
                "\(keychainItems.filter { $0.vaultID == vault.id }.count) keychain"
            ])
        }
        return ProfileSorting.sortVaults(filteredVaults, by: sortOption)
    }

    var body: some View {
        Group {
            if vaults.isEmpty {
                ContentUnavailableView("Preparing Vault", systemImage: "archivebox")
            } else if vaults.count == 1, let vault = vaults.first {
                VaultDashboardView(vault: vault)
            } else if searchedVaults.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List(searchedVaults) { vault in
                    NavigationLink(value: VaultsRoute.vaultDashboard(vault.id)) {
                        VaultListRow(
                            vault: vault,
                            hostsCount: hosts.filter { $0.vaultID == vault.id }.count,
                            keychainCount: keychainItems.filter { $0.vaultID == vault.id }.count
                        )
                    }
                }
            }
        }
        .navigationTitle(vaults.count <= 1 ? "Vaults" : "All Vaults")
        .searchable(text: $searchText, prompt: "Search vaults")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if vaults.count > 1 {
                    SortOptionsMenu(selection: $sortOptionRawValue.sortOption(VaultSortOption.self, default: .name))
                }

                Button {
                    isAddingVault = true
                } label: {
                    Label("Add Vault", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $isAddingVault) {
            VaultEditorView(existingNames: vaults.map(\.name)) { name in
                let vault = VaultProfile(name: name)
                modelContext.insert(vault)
                try modelContext.save()
                syncUnlockStore.scheduleUploadCurrentData(
                    vaults: vaults.filter { $0.id != vault.id } + [vault],
                    hosts: hosts,
                    keychainItems: keychainItems,
                    snippets: snippets,
                    secureSecretStore: secureSecretStore
                )
            }
        }
        .task {
            ensurePersonalVault()
        }
    }

    private func ensurePersonalVault() {
        guard vaults.isEmpty else { return }
        modelContext.insert(VaultProfile(name: "Personal Vault"))
        try? modelContext.save()
    }
}

private struct VaultListRow: View {
    let vault: VaultProfile
    let hostsCount: Int
    let keychainCount: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "archivebox")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(vault.name)
                    .font(.headline)
                Text("\(hostsCount) hosts · \(keychainCount) keychain items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct VaultDashboardRouteView: View {
    @Query private var vaults: [VaultProfile]
    let vaultID: UUID

    var body: some View {
        if let vault = vaults.first(where: { $0.id == vaultID }) {
            VaultDashboardView(vault: vault)
        } else {
            ContentUnavailableView("Vault Not Found", systemImage: "archivebox")
        }
    }
}

struct VaultDashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncUnlockStore.self) private var syncUnlockStore
    @Environment(SecureSecretStore.self) private var secureSecretStore
    @Environment(TerminalSessionManager.self) private var terminalSessionManager
    @Environment(TabRouter.self) private var router
    @Query private var vaults: [VaultProfile]
    @Query private var hosts: [HostProfile]
    @Query private var keychainItems: [KeychainItemProfile]
    @Query private var snippets: [SnippetProfile]

    let vault: VaultProfile
    @State private var isEditingVault = false
    @State private var isConfirmingVaultDelete = false
    @State private var vaultError: String?

    private var vaultHosts: [HostProfile] {
        hosts.filter { $0.vaultID == vault.id }
    }

    private var vaultKeychainItems: [KeychainItemProfile] {
        keychainItems.filter { $0.vaultID == vault.id }
    }

    private var vaultSnippets: [SnippetProfile] {
        snippets.filter { $0.vaultID == vault.id }
    }

    var body: some View {
        List {
            if let vaultError {
                Section {
                    Text(vaultError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(vault.name)
                        .font(.title2.bold())
                    Text("\(vaultHosts.count) hosts · \(vaultKeychainItems.count) keychain items · \(vaultSnippets.count) snippets")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("Workspace") {
                NavigationLink(value: VaultsRoute.hosts(vault.id)) {
                    Label("Hosts", systemImage: "server.rack")
                }
                .popoverTip(VaultIntroTipState.hostTip(hostCount: vaultHosts.count, keychainItemCount: vaultKeychainItems.count))
                NavigationLink(value: VaultsRoute.keychain(vault.id)) {
                    Label("Keychain", systemImage: "key.fill")
                }
                .popoverTip(VaultIntroTipState.keychainTip(hostCount: vaultHosts.count, keychainItemCount: vaultKeychainItems.count))
                NavigationLink(value: VaultsRoute.snippets(vault.id)) {
                    Label("Snippets", systemImage: "text.badge.plus")
                }
            }
        }
        .navigationTitle(vault.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        isEditingVault = true
                    } label: {
                        Label("Rename Vault", systemImage: "pencil")
                    }

                    Button(role: .destructive) {
                        isConfirmingVaultDelete = true
                    } label: {
                        Label("Delete Vault", systemImage: "trash")
                    }
                    .disabled(vaults.count <= 1)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $isEditingVault) {
            VaultEditorView(
                initialName: vault.name,
                existingNames: vaults.filter { $0.id != vault.id }.map(\.name)
            ) { name in
                vault.name = name
                vault.updatedAt = .now
                try modelContext.save()
                syncUnlockStore.scheduleUploadCurrentData(
                    vaults: vaults,
                    hosts: hosts,
                    keychainItems: keychainItems,
                    snippets: snippets,
                    secureSecretStore: secureSecretStore
                )
            }
        }
        .confirmationDialog(
            "Delete \(vault.name)?",
            isPresented: $isConfirmingVaultDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Vault", role: .destructive) {
                deleteVault()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hosts, keychain metadata, and Keychain secrets in this vault will be removed from this device.")
        }
    }

    private func deleteVault() {
        guard vaults.count > 1 else {
            vaultError = "At least one vault must remain."
            return
        }

        vaultError = nil
        let vaultID = vault.id
        let deletedKeychainItems = keychainItems.filter { $0.vaultID == vaultID }
        let deletedAccounts = deletedKeychainItems.flatMap { item in
            [item.secretAccount, item.passphraseAccount].compactMap(\.self)
        }

        for host in hosts where host.vaultID == vaultID {
            modelContext.delete(host)
        }
        for item in deletedKeychainItems {
            modelContext.delete(item)
        }
        for snippet in snippets where snippet.vaultID == vaultID {
            modelContext.delete(snippet)
        }
        modelContext.delete(vault)

        do {
            try modelContext.save()
            terminalSessionManager.closeSessions(forVaultID: vaultID)
            router.popToRoot(.vaults)

            let remainingVaults = vaults.filter { $0.id != vaultID }
            let remainingHosts = hosts.filter { $0.vaultID != vaultID }
            let remainingItems = keychainItems.filter { $0.vaultID != vaultID }
            let remainingSnippets = snippets.filter { $0.vaultID != vaultID }

            Task {
                for account in deletedAccounts {
                    try? await secureSecretStore.deleteVaultSecret(account: account)
                }
                syncUnlockStore.scheduleUploadCurrentData(
                    vaults: remainingVaults,
                    hosts: remainingHosts,
                    keychainItems: remainingItems,
                    snippets: remainingSnippets,
                    secureSecretStore: secureSecretStore
                )
            }
        } catch {
            vaultError = error.localizedDescription
        }
    }
}

struct HostsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncUnlockStore.self) private var syncUnlockStore
    @Environment(SecureSecretStore.self) private var secureSecretStore
    @Environment(TerminalSessionManager.self) private var terminalSessionManager
    @Query(sort: \VaultProfile.createdAt) private var vaults: [VaultProfile]
    @Query(sort: \HostProfile.alias) private var hosts: [HostProfile]
    @Query(sort: \KeychainItemProfile.name) private var keychainItems: [KeychainItemProfile]
    @Query(sort: \SnippetProfile.title) private var snippets: [SnippetProfile]

    let vaultID: UUID
    @State private var isAddingHost = false
    @State private var deletionError: String?
    @State private var searchText = ""
    @AppStorage("hostsSortOption") private var sortOptionRawValue = HostSortOption.alias.rawValue

    private var sortOption: HostSortOption {
        SortOptionStorage.value(from: sortOptionRawValue, default: .alias)
    }

    private var vaultHosts: [HostProfile] {
        hosts.filter { $0.vaultID == vaultID }
    }

    private var searchedHosts: [HostProfile] {
        let filteredHosts = vaultHosts.filter { host in
            ProfileSearch.matches(searchText, fields: [
                host.alias,
                host.host,
                host.username,
                host.authMethod.title,
                host.notes
            ])
        }
        return ProfileSorting.sortHosts(filteredHosts, by: sortOption)
    }

    var body: some View {
        List {
            if let deletionError {
                Section {
                    Text(deletionError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if vaultHosts.isEmpty {
                ContentUnavailableView("No Hosts", systemImage: "server.rack", description: Text("Add a server profile to start a terminal session."))
            } else if searchedHosts.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                ForEach(searchedHosts) { host in
                    NavigationLink(value: VaultsRoute.hostDetail(host.id)) {
                        HostRow(host: host)
                    }
                }
                .onDelete(perform: deleteHosts)
            }
        }
        .navigationTitle("Hosts")
        .searchable(text: $searchText, prompt: "Search hosts")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if vaultHosts.count > 1 {
                    SortOptionsMenu(selection: $sortOptionRawValue.sortOption(HostSortOption.self, default: .alias))
                }

                Button {
                    isAddingHost = true
                } label: {
                    Label("Add Host", systemImage: "plus")
                }
                .popoverTip(VaultIntroTipState.hostTip(hostCount: vaultHosts.count, keychainItemCount: vaultKeychainItems.count))
            }
        }
        .sheet(isPresented: $isAddingHost) {
            HostEditorView(vaultID: vaultID)
        }
    }

    private var vaultKeychainItems: [KeychainItemProfile] {
        keychainItems.filter { $0.vaultID == vaultID }
    }

    private func deleteHosts(at offsets: IndexSet) {
        let deletedIDs = Set(offsets.map { searchedHosts[$0].id })
        for index in offsets {
            modelContext.delete(searchedHosts[index])
        }

        do {
            try modelContext.save()
            deletionError = nil
        } catch {
            modelContext.rollback()
            deletionError = error.localizedDescription
            return
        }

        for hostID in deletedIDs {
            terminalSessionManager.closeSessions(forHostID: hostID)
        }
        let remainingHosts = hosts.filter { !deletedIDs.contains($0.id) }
        syncUnlockStore.scheduleUploadCurrentData(
            vaults: vaults,
            hosts: remainingHosts,
            keychainItems: keychainItems,
            snippets: snippets,
            secureSecretStore: secureSecretStore
        )
    }
}

private struct HostRow: View {
    let host: HostProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(host.alias)
                .font(.headline)
            Text("\(host.username)@\(host.host):\(host.port)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(host.authMethod.title)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

struct HostDetailRouteView: View {
    @Environment(TabRouter.self) private var router
    @Environment(TerminalSessionManager.self) private var terminalSessionManager
    @Environment(SecureSecretStore.self) private var secureSecretStore
    @Query private var hosts: [HostProfile]
    @Query private var keychainItems: [KeychainItemProfile]

    let hostID: UUID
    @State private var isEditingHost = false
    @State private var connectionError: String?

    var body: some View {
        if let host = hosts.first(where: { $0.id == hostID }) {
            List {
                if let connectionError {
                    Section {
                        Text(connectionError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section("Connection") {
                    LabeledContent("Alias", value: host.alias)
                    LabeledContent("Host", value: host.host)
                    LabeledContent("Port", value: "\(host.port)")
                    LabeledContent("Username", value: host.username)
                    LabeledContent("Auth", value: host.authMethod.title)
                    if let item = keychainItems.first(where: { $0.id == host.linkedKeychainItemID }) {
                        LabeledContent("Keychain", value: item.name)
                    }
                    if !host.notes.isEmpty {
                        LabeledContent("Notes", value: host.notes)
                    }
                }

                Section {
                    Button {
                        connect(host)
                    } label: {
                        Label("Connect", systemImage: "terminal")
                    }
                    .disabled(linkedKeychainItem(for: host) == nil)

                    if linkedKeychainItem(for: host) == nil {
                        Text("A matching keychain item is required before starting a terminal session.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(host.alias)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isEditingHost = true
                    } label: {
                        Label("Edit Host", systemImage: "pencil")
                    }
                }
            }
            .sheet(isPresented: $isEditingHost) {
                HostEditorView(vaultID: host.vaultID, hostToEdit: host)
            }
        } else {
            ContentUnavailableView("Host Not Found", systemImage: "server.rack")
        }
    }

    private func linkedKeychainItem(for host: HostProfile) -> KeychainItemProfile? {
        keychainItems.first { item in
            item.id == host.linkedKeychainItemID
                && item.vaultID == host.vaultID
                && item.kind.rawValue == host.authMethod.rawValue
        }
    }

    private func connect(_ host: HostProfile) {
        guard let keychainItem = linkedKeychainItem(for: host) else {
            connectionError = "Select a matching keychain item before connecting."
            return
        }

        connectionError = nil
        let sessionID = terminalSessionManager.createConnectingSession(for: host)
        router.openTerminalSession(sessionID)
        terminalSessionManager.noteSessionStatus(sessionID, message: "Loading SSH credential from Keychain.")

        Task {
            do {
                let auth: SSHAuthenticationConfig
                switch host.authMethod {
                case .password:
                    guard let password = try await secureSecretStore.loadVaultSecret(account: keychainItem.secretAccount),
                          !password.isEmpty
                    else {
                        terminalSessionManager.failSession(sessionID, message: "Missing SSH password in Keychain.")
                        return
                    }
                    auth = .password(password)
                    terminalSessionManager.noteSessionStatus(sessionID, message: "Loaded SSH password credential.")
                case .sshKey:
                    guard let privateKey = try await secureSecretStore.loadVaultSecret(account: keychainItem.secretAccount),
                          !privateKey.isEmpty
                    else {
                        terminalSessionManager.failSession(sessionID, message: "Missing SSH private key in Keychain.")
                        return
                    }
                    let passphrase: String?
                    if let passphraseAccount = keychainItem.passphraseAccount {
                        passphrase = try await secureSecretStore.loadVaultSecret(account: passphraseAccount)
                    } else {
                        passphrase = nil
                    }
                    auth = .privateKey(privateKey, passphrase: passphrase)
                    terminalSessionManager.noteSessionStatus(sessionID, message: "Loaded SSH private key credential.")
                case .identity:
                    terminalSessionManager.failSession(sessionID, message: "Identity auth is not supported yet.")
                    return
                }

                let config = SSHConnectionConfig(
                    host: host.host,
                    port: host.port,
                    username: host.username,
                    auth: auth
                )
                terminalSessionManager.noteSessionStatus(sessionID, message: "Starting SSH session driver.")
                terminalSessionManager.openSession(sessionID, config: config)
            } catch {
                terminalSessionManager.failSession(sessionID, message: error.localizedDescription)
            }
        }
    }
}

struct HostEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncUnlockStore.self) private var syncUnlockStore
    @Environment(SecureSecretStore.self) private var secureSecretStore
    @Query(sort: \VaultProfile.createdAt) private var vaults: [VaultProfile]
    @Query(sort: \HostProfile.alias) private var hosts: [HostProfile]
    @Query(sort: \KeychainItemProfile.name) private var keychainItems: [KeychainItemProfile]
    @Query(sort: \SnippetProfile.title) private var snippets: [SnippetProfile]

    let vaultID: UUID
    let hostToEdit: HostProfile?

    @State private var alias = ""
    @State private var host = ""
    @State private var port = 22
    @State private var username = ""
    @State private var authMethod: HostAuthMethod = .password
    @State private var linkedKeychainItemID: UUID?
    @State private var notes = ""
    @State private var errorMessage: String?

    private var compatibleKeychainItems: [KeychainItemProfile] {
        guard let kind = KeychainItemKind(rawValue: authMethod.rawValue) else {
            return []
        }
        return keychainItems.filter { $0.vaultID == vaultID && $0.kind == kind }
    }

    private var validationMessages: [String] {
        let existingAliases = hosts
            .filter { $0.vaultID == vaultID && $0.id != hostToEdit?.id }
            .map(\.alias)
        return ProfileValidation.hostMessages(
            alias: alias,
            host: host,
            username: username,
            port: port,
            existingAliases: existingAliases,
            linkedKeychainItemID: linkedKeychainItemID,
            requiresLinkedKeychainItem: true
        )
    }

    private var canSave: Bool {
        validationMessages.isEmpty
    }

    init(vaultID: UUID, hostToEdit: HostProfile? = nil) {
        self.vaultID = vaultID
        self.hostToEdit = hostToEdit
        _alias = State(initialValue: hostToEdit?.alias ?? "")
        _host = State(initialValue: hostToEdit?.host ?? "")
        _port = State(initialValue: hostToEdit?.port ?? 22)
        _username = State(initialValue: hostToEdit?.username ?? "")
        _authMethod = State(initialValue: hostToEdit?.authMethod ?? .password)
        _linkedKeychainItemID = State(initialValue: hostToEdit?.linkedKeychainItemID)
        _notes = State(initialValue: hostToEdit?.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Alias", text: $alias)
                    TextField("Host", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Stepper("Port: \(port)", value: $port, in: 1...65535)
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    ValidationMessagesView(messages: validationMessages)
                }

                Section("Authentication") {
                    Picker("Method", selection: $authMethod) {
                        ForEach(HostAuthMethod.allCases) { method in
                            Text(method.title).tag(method)
                        }
                    }

                    Picker("Keychain Item", selection: $linkedKeychainItemID) {
                        Text("None").tag(UUID?.none)
                        ForEach(compatibleKeychainItems) { item in
                            Text(item.name).tag(Optional(item.id))
                        }
                    }
                    Text("Only keychain items that match the selected auth method are shown.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Notes") {
                    TextField("Optional notes", text: $notes, axis: .vertical)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(hostToEdit == nil ? "New Host" : "Edit Host")
            .onChange(of: authMethod) {
                linkedKeychainItemID = nil
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!canSave)
                }
            }
        }
    }

    private func save() {
        guard validationMessages.isEmpty else { return }

        let trimmedAlias = ProfileValidation.trimmed(alias)
        let trimmedHost = ProfileValidation.trimmed(host)
        let trimmedUsername = ProfileValidation.trimmed(username)

        let syncHosts: [HostProfile]
        if let hostToEdit {
            hostToEdit.alias = trimmedAlias
            hostToEdit.host = trimmedHost
            hostToEdit.port = port
            hostToEdit.username = trimmedUsername
            hostToEdit.authMethod = authMethod
            hostToEdit.linkedKeychainItemID = linkedKeychainItemID
            hostToEdit.notes = notes
            hostToEdit.updatedAt = .now
            syncHosts = hosts
        } else {
            let profile = HostProfile(
                vaultID: vaultID,
                alias: trimmedAlias,
                host: trimmedHost,
                port: port,
                username: trimmedUsername,
                authMethod: authMethod,
                linkedKeychainItemID: linkedKeychainItemID,
                notes: notes
            )
            modelContext.insert(profile)
            syncHosts = hosts.filter { $0.id != profile.id } + [profile]
        }

        do {
            try modelContext.save()
            errorMessage = nil
            if hostToEdit == nil {
                AddHostProfileTip().invalidate(reason: .actionPerformed)
            }
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
            return
        }

        syncUnlockStore.scheduleUploadCurrentData(
            vaults: vaults,
            hosts: syncHosts,
            keychainItems: keychainItems,
            snippets: snippets,
            secureSecretStore: secureSecretStore
        )
        dismiss()
    }
}

private struct VaultEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let initialName: String
    let existingNames: [String]
    let onSave: (String) throws -> Void

    @State private var name: String
    @State private var errorMessage: String?

    private var trimmedName: String {
        ProfileValidation.trimmed(name)
    }

    private var validationMessages: [String] {
        ProfileValidation.vaultNameMessages(name, existingNames: existingNames)
    }

    private var canSave: Bool {
        validationMessages.isEmpty
    }

    init(initialName: String = "", existingNames: [String] = [], onSave: @escaping (String) throws -> Void) {
        self.initialName = initialName
        self.existingNames = existingNames
        self.onSave = onSave
        _name = State(initialValue: initialName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Vault") {
                    TextField("Name", text: $name)

                    ValidationMessagesView(messages: validationMessages)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(initialName.isEmpty ? "New Vault" : "Rename Vault")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!canSave)
                }
            }
        }
    }

    private func save() {
        guard validationMessages.isEmpty else {
            errorMessage = validationMessages.first
            return
        }

        do {
            try onSave(trimmedName)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
