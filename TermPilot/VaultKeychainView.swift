import SwiftData
import SwiftUI
import TipKit

struct VaultKeychainListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncUnlockStore.self) private var syncUnlockStore
    @Environment(SecureSecretStore.self) private var secureSecretStore
    @Query(sort: \VaultProfile.createdAt) private var vaults: [VaultProfile]
    @Query(sort: \HostProfile.alias) private var hosts: [HostProfile]
    @Query(sort: \KeychainItemProfile.name) private var items: [KeychainItemProfile]
    @Query(sort: \SnippetProfile.title) private var snippets: [SnippetProfile]

    let vaultID: UUID
    @State private var isAddingItem = false
    @State private var deletionError: String?
    @State private var searchText = ""
    @AppStorage("keychainSortOption") private var sortOptionRawValue = KeychainSortOption.name.rawValue

    private var sortOption: KeychainSortOption {
        SortOptionStorage.value(from: sortOptionRawValue, default: .name)
    }

    private var vaultItems: [KeychainItemProfile] {
        items.filter { $0.vaultID == vaultID }
    }

    private var vaultHosts: [HostProfile] {
        hosts.filter { $0.vaultID == vaultID }
    }

    private var searchedItems: [KeychainItemProfile] {
        let filteredItems = vaultItems.filter { item in
            ProfileSearch.matches(searchText, fields: [
                item.name,
                item.kind.title,
                item.username,
                item.fingerprint
            ])
        }
        return ProfileSorting.sortKeychainItems(filteredItems, by: sortOption)
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

            ForEach(KeychainItemKind.allCases) { kind in
                let filtered = searchedItems.filter { $0.kind == kind }
                Section(kind.title) {
                    if vaultItems.filter({ $0.kind == kind }).isEmpty {
                        Text("No \(kind.title.lowercased()) items")
                            .foregroundStyle(.secondary)
                    } else if filtered.isEmpty {
                        Text("No matches")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filtered) { item in
                            NavigationLink(value: VaultsRoute.keychainItem(item.id)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.name)
                                        .font(.headline)
                                    if !item.username.isEmpty {
                                        Text(item.username)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    if !item.fingerprint.isEmpty {
                                        Text(item.fingerprint)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                        .onDelete { offsets in
                            deleteItems(filtered, offsets: offsets)
                        }
                    }
                }
            }
        }
        .navigationTitle("Keychain")
        .searchable(text: $searchText, prompt: "Search keychain")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if vaultItems.count > 1 {
                    SortOptionsMenu(selection: $sortOptionRawValue.sortOption(KeychainSortOption.self, default: .name))
                }

                Button {
                    isAddingItem = true
                } label: {
                    Label("Add Keychain Item", systemImage: "plus")
                }
                .popoverTip(VaultIntroTipState.keychainTip(hostCount: vaultHosts.count, keychainItemCount: vaultItems.count))
            }
        }
        .sheet(isPresented: $isAddingItem) {
            KeychainItemEditorView(vaultID: vaultID)
        }
    }

    private func deleteItems(_ source: [KeychainItemProfile], offsets: IndexSet) {
        let deletedItems = offsets.map { source[$0] }
        let referencedItems = deletedItems.filter { item in
            hosts.contains { $0.linkedKeychainItemID == item.id }
        }
        guard referencedItems.isEmpty else {
            let names = referencedItems.map(\.name).joined(separator: ", ")
            deletionError = "Cannot delete \(names) while linked hosts still use it."
            return
        }

        deletionError = nil
        let deletedIDs = Set(deletedItems.map(\.id))
        let deletedAccounts = deletedItems.flatMap { item in
            [item.secretAccount, item.passphraseAccount].compactMap(\.self)
        }

        for index in offsets {
            let item = source[index]
            modelContext.delete(item)
        }

        do {
            try modelContext.save()
            deletionError = nil
        } catch {
            modelContext.rollback()
            deletionError = error.localizedDescription
            return
        }

        let remainingItems = items.filter { !deletedIDs.contains($0.id) }
        Task {
            for account in deletedAccounts {
                try? await secureSecretStore.deleteVaultSecret(account: account)
            }
            syncUnlockStore.scheduleUploadCurrentData(
                vaults: vaults,
                hosts: hosts,
                keychainItems: remainingItems,
                snippets: snippets,
                secureSecretStore: secureSecretStore
            )
        }
    }
}

struct KeychainItemDetailRouteView: View {
    @Query private var hosts: [HostProfile]
    @Query private var items: [KeychainItemProfile]
    let itemID: UUID
    @State private var isEditingItem = false

    var body: some View {
        if let item = items.first(where: { $0.id == itemID }) {
            let linkedHostCount = hosts.filter { $0.linkedKeychainItemID == item.id }.count

            List {
                Section("Metadata") {
                    LabeledContent("Name", value: item.name)
                    LabeledContent("Type", value: item.kind.title)
                    if !item.username.isEmpty {
                        LabeledContent("Username", value: item.username)
                    }
                    if !item.fingerprint.isEmpty {
                        LabeledContent("Fingerprint", value: item.fingerprint)
                    }
                    LabeledContent("Linked Hosts", value: "\(linkedHostCount)")
                }

                Section {
                    Label("Secret body is stored in Keychain", systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(item.name)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isEditingItem = true
                    } label: {
                        Label("Edit Keychain Item", systemImage: "pencil")
                    }
                }
            }
            .sheet(isPresented: $isEditingItem) {
                KeychainItemEditorView(vaultID: item.vaultID, itemToEdit: item)
            }
        } else {
            ContentUnavailableView("Keychain Item Not Found", systemImage: "key.fill")
        }
    }
}

struct KeychainItemEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncUnlockStore.self) private var syncUnlockStore
    @Environment(SecureSecretStore.self) private var secureSecretStore
    @Query(sort: \VaultProfile.createdAt) private var vaults: [VaultProfile]
    @Query(sort: \HostProfile.alias) private var hosts: [HostProfile]
    @Query(sort: \KeychainItemProfile.name) private var items: [KeychainItemProfile]
    @Query(sort: \SnippetProfile.title) private var snippets: [SnippetProfile]

    let vaultID: UUID
    let itemToEdit: KeychainItemProfile?

    @State private var name = ""
    @State private var kind: KeychainItemKind = .password
    @State private var username = ""
    @State private var secret = ""
    @State private var passphrase = ""
    @State private var fingerprint = ""
    @State private var errorMessage: String?
    @State private var isSaving = false

    private var linkedHostCount: Int {
        guard let itemToEdit else { return 0 }
        return hosts.filter { $0.linkedKeychainItemID == itemToEdit.id }.count
    }

    private var isLinkedToHosts: Bool {
        linkedHostCount > 0
    }

    private var validationMessages: [String] {
        let existingNames = items
            .filter { $0.vaultID == vaultID && $0.id != itemToEdit?.id }
            .map(\.name)
        return ProfileValidation.keychainItemMessages(
            name: name,
            secret: secret,
            kind: kind,
            existingNames: existingNames,
            originalKind: itemToEdit?.kind,
            isLinkedToHosts: isLinkedToHosts
        )
    }

    private var canSave: Bool {
        validationMessages.isEmpty && !isSaving
    }

    init(vaultID: UUID, itemToEdit: KeychainItemProfile? = nil) {
        self.vaultID = vaultID
        self.itemToEdit = itemToEdit
        _name = State(initialValue: itemToEdit?.name ?? "")
        _kind = State(initialValue: itemToEdit?.kind ?? .password)
        _username = State(initialValue: itemToEdit?.username ?? "")
        _fingerprint = State(initialValue: itemToEdit?.fingerprint ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Metadata") {
                    TextField("Name", text: $name)
                    Picker("Type", selection: $kind) {
                        ForEach(KeychainItemKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .disabled(isLinkedToHosts)
                    if isLinkedToHosts {
                        Text("Type is locked because \(linkedHostCount) linked host\(linkedHostCount == 1 ? "" : "s") use this item.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if kind == .sshKey {
                        TextField("Fingerprint", text: $fingerprint)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                Section("Secret") {
                    SecureField(kind == .sshKey ? "Private key" : "Password", text: $secret)

                    if kind == .sshKey {
                        SecureField("Passphrase (optional)", text: $passphrase)
                    }

                    ValidationMessagesView(messages: validationMessages)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if itemToEdit != nil {
                        Text("Saving replaces the Keychain secret for this item.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(itemToEdit == nil ? "New Keychain Item" : "Edit Keychain Item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving" : "Save") {
                        save()
                    }
                    .disabled(!canSave)
                }
            }
            .task {
                await loadExistingSecretIfNeeded()
            }
        }
    }

    private func save() {
        guard validationMessages.isEmpty else {
            errorMessage = validationMessages.first
            return
        }

        isSaving = true
        errorMessage = nil

        let itemID = itemToEdit?.id ?? UUID()
        let account = itemToEdit?.secretAccount ?? "vault-secret-\(itemID.uuidString)"
        let secretValue = secret
        let trimmedPassphrase = ProfileValidation.trimmed(passphrase)
        let oldPassphraseAccount = itemToEdit?.passphraseAccount
        let newPassphraseAccount = kind == .sshKey && !trimmedPassphrase.isEmpty
            ? oldPassphraseAccount ?? "vault-secret-passphrase-\(itemID.uuidString)"
            : nil
        let trimmedName = ProfileValidation.trimmed(name)
        let trimmedUsername = ProfileValidation.trimmed(username)
        let trimmedFingerprint = kind == .sshKey ? ProfileValidation.trimmed(fingerprint) : ""

        Task {
            do {
                try await secureSecretStore.saveVaultSecret(secretValue, account: account)
                if let newPassphraseAccount {
                    try await secureSecretStore.saveVaultSecret(trimmedPassphrase, account: newPassphraseAccount)
                }
                if let oldPassphraseAccount, oldPassphraseAccount != newPassphraseAccount {
                    try await secureSecretStore.deleteVaultSecret(account: oldPassphraseAccount)
                }

                let syncItems: [KeychainItemProfile]
                if let itemToEdit {
                    itemToEdit.name = trimmedName
                    itemToEdit.kind = kind
                    itemToEdit.username = trimmedUsername
                    itemToEdit.fingerprint = trimmedFingerprint
                    itemToEdit.passphraseAccount = newPassphraseAccount
                    itemToEdit.updatedAt = .now
                    syncItems = items
                } else {
                    let profile = KeychainItemProfile(
                        id: itemID,
                        vaultID: vaultID,
                        name: trimmedName,
                        kind: kind,
                        username: trimmedUsername,
                        fingerprint: trimmedFingerprint,
                        secretAccount: account,
                        passphraseAccount: newPassphraseAccount
                    )
                    modelContext.insert(profile)
                    syncItems = items.filter { $0.id != profile.id } + [profile]
                }
                try modelContext.save()
                if itemToEdit == nil {
                    AddKeychainLoginMethodTip().invalidate(reason: .actionPerformed)
                }
                syncUnlockStore.scheduleUploadCurrentData(
                    vaults: vaults,
                    hosts: hosts,
                    keychainItems: syncItems,
                    snippets: snippets,
                    secureSecretStore: secureSecretStore
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func loadExistingSecretIfNeeded() async {
        guard let itemToEdit, secret.isEmpty else { return }

        do {
            secret = try await secureSecretStore.loadVaultSecret(account: itemToEdit.secretAccount) ?? ""
            if let passphraseAccount = itemToEdit.passphraseAccount {
                passphrase = try await secureSecretStore.loadVaultSecret(account: passphraseAccount) ?? ""
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct SnippetsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncUnlockStore.self) private var syncUnlockStore
    @Environment(SecureSecretStore.self) private var secureSecretStore
    @Query(sort: \VaultProfile.createdAt) private var vaults: [VaultProfile]
    @Query(sort: \HostProfile.alias) private var hosts: [HostProfile]
    @Query(sort: \KeychainItemProfile.name) private var keychainItems: [KeychainItemProfile]
    @Query(sort: \SnippetProfile.title) private var snippets: [SnippetProfile]

    let vaultID: UUID
    @State private var isAddingSnippet = false
    @State private var snippetToEdit: SnippetProfile?
    @State private var deletionError: String?
    @State private var searchText = ""
    @AppStorage("snippetsSortOption") private var sortOptionRawValue = SnippetSortOption.title.rawValue

    private var sortOption: SnippetSortOption {
        SortOptionStorage.value(from: sortOptionRawValue, default: .title)
    }

    private var vaultSnippets: [SnippetProfile] {
        snippets.filter { $0.vaultID == vaultID }
    }

    private var searchedSnippets: [SnippetProfile] {
        let filteredSnippets = vaultSnippets.filter { snippet in
            ProfileSearch.matches(searchText, fields: [
                snippet.title,
                snippet.command,
                snippet.notes
            ])
        }
        return ProfileSorting.sortSnippets(filteredSnippets, by: sortOption)
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

            if vaultSnippets.isEmpty {
                ContentUnavailableView(
                    "No Snippets",
                    systemImage: "text.badge.plus",
                    description: Text("Save reusable shell commands for this vault.")
                )
            } else if searchedSnippets.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                ForEach(searchedSnippets) { snippet in
                    Button {
                        snippetToEdit = snippet
                    } label: {
                        SnippetRow(snippet: snippet)
                    }
                    .foregroundStyle(.primary)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            deleteSnippet(snippet)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }

                        Button {
                            snippetToEdit = snippet
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
            }
        }
        .navigationTitle("Snippets")
        .searchable(text: $searchText, prompt: "Search snippets")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if vaultSnippets.count > 1 {
                    SortOptionsMenu(selection: $sortOptionRawValue.sortOption(SnippetSortOption.self, default: .title))
                }

                Button {
                    isAddingSnippet = true
                } label: {
                    Label("Add Snippet", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $isAddingSnippet) {
            SnippetEditorView(vaultID: vaultID)
        }
        .sheet(item: $snippetToEdit) { snippet in
            SnippetEditorView(vaultID: vaultID, snippetToEdit: snippet)
        }
    }

    private func deleteSnippet(_ snippet: SnippetProfile) {
        let deletedID = snippet.id
        modelContext.delete(snippet)

        do {
            try modelContext.save()
            deletionError = nil
        } catch {
            modelContext.rollback()
            deletionError = error.localizedDescription
            return
        }

        syncUnlockStore.scheduleUploadCurrentData(
            vaults: vaults,
            hosts: hosts,
            keychainItems: keychainItems,
            snippets: snippets.filter { $0.id != deletedID },
            secureSecretStore: secureSecretStore
        )
    }
}

private struct SnippetRow: View {
    let snippet: SnippetProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(snippet.title)
                .font(.headline)
            Text(snippet.command)
                .font(.caption.monospaced())
                .lineLimit(2)
                .foregroundStyle(.secondary)
            if !snippet.notes.isEmpty {
                Text(snippet.notes)
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct SnippetEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncUnlockStore.self) private var syncUnlockStore
    @Environment(SecureSecretStore.self) private var secureSecretStore
    @Query(sort: \VaultProfile.createdAt) private var vaults: [VaultProfile]
    @Query(sort: \HostProfile.alias) private var hosts: [HostProfile]
    @Query(sort: \KeychainItemProfile.name) private var keychainItems: [KeychainItemProfile]
    @Query(sort: \SnippetProfile.title) private var snippets: [SnippetProfile]

    let vaultID: UUID
    let snippetToEdit: SnippetProfile?

    @State private var title: String
    @State private var command: String
    @State private var notes: String
    @State private var errorMessage: String?

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedCommand: String {
        command.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        validationMessages.isEmpty
    }

    private var validationMessages: [String] {
        let existingTitles = snippets
            .filter { $0.vaultID == vaultID && $0.id != snippetToEdit?.id }
            .map(\.title)
        return ProfileValidation.snippetMessages(
            title: title,
            command: command,
            existingTitles: existingTitles
        )
    }

    init(vaultID: UUID, snippetToEdit: SnippetProfile? = nil) {
        self.vaultID = vaultID
        self.snippetToEdit = snippetToEdit
        _title = State(initialValue: snippetToEdit?.title ?? "")
        _command = State(initialValue: snippetToEdit?.command ?? "")
        _notes = State(initialValue: snippetToEdit?.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Snippet") {
                    TextField("Title", text: $title)
                    TextField("Command", text: $command, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        .lineLimit(3...8)

                    ValidationMessagesView(messages: validationMessages)
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
            .navigationTitle(snippetToEdit == nil ? "New Snippet" : "Edit Snippet")
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

        let syncSnippets: [SnippetProfile]
        if let snippetToEdit {
            snippetToEdit.title = trimmedTitle
            snippetToEdit.command = trimmedCommand
            snippetToEdit.notes = notes
            snippetToEdit.updatedAt = .now
            syncSnippets = snippets
        } else {
            let snippet = SnippetProfile(
                vaultID: vaultID,
                title: trimmedTitle,
                command: trimmedCommand,
                notes: notes
            )
            modelContext.insert(snippet)
            syncSnippets = snippets.filter { $0.id != snippet.id } + [snippet]
        }

        do {
            try modelContext.save()
            errorMessage = nil
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
            return
        }

        syncUnlockStore.scheduleUploadCurrentData(
            vaults: vaults,
            hosts: hosts,
            keychainItems: keychainItems,
            snippets: syncSnippets,
            secureSecretStore: secureSecretStore
        )
        dismiss()
    }
}
