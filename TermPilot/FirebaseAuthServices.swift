import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import GoogleSignIn
import UIKit

protocol AuthRepository {
    func restoreUser() async throws -> CurrentUser?
    func signInWithGoogle(presenting viewController: UIViewController) async throws -> CurrentUser
    func signOut() async throws
}

protocol SyncBlobRepository {
    func fetchLatest(uid: String) async throws -> SyncBlobDocument?
    func save(_ document: SyncBlobDocument, uid: String) async throws
    func delete(uid: String) async throws
}

enum FirebaseIntegrationError: LocalizedError {
    case missingConfigurationFile
    case missingGoogleClientID
    case missingPresentingViewController
    case missingGoogleIDToken
    case signInCancelled
    case invalidSyncDocument(String)

    var errorDescription: String? {
        switch self {
        case .missingConfigurationFile:
            "Missing Firebase configuration. Add GoogleService-Info.plist to the TermPilot app target."
        case .missingGoogleClientID:
            "Missing Google client ID. Check CLIENT_ID in GoogleService-Info.plist or GIDClientID in Info.plist."
        case .missingPresentingViewController:
            "Unable to present Google Sign-In from the current scene."
        case .missingGoogleIDToken:
            "Google Sign-In did not return an ID token."
        case .signInCancelled:
            "Google Sign-In was cancelled."
        case .invalidSyncDocument(let message):
            "Invalid Firestore sync document: \(message)"
        }
    }
}

struct FirebaseAuthRepository: AuthRepository {
    func restoreUser() async throws -> CurrentUser? {
        guard FirebaseApp.app() != nil else {
            return nil
        }

        if let user = Auth.auth().currentUser {
            return CurrentUser(firebaseUser: user)
        }

        configureGoogleSignIn()
        guard let googleUser = try await restorePreviousGoogleSignIn() else {
            return nil
        }
        return try await signInToFirebase(with: googleUser)
    }

    func signInWithGoogle(presenting viewController: UIViewController) async throws -> CurrentUser {
        configureGoogleSignIn()
        let result = try await googleSignIn(presenting: viewController)
        return try await signInToFirebase(with: result.user)
    }

    func signOut() async throws {
        GIDSignIn.sharedInstance.signOut()
        guard FirebaseApp.app() != nil else { return }
        try Auth.auth().signOut()
    }

    private func configureGoogleSignIn() {
        guard FirebaseApp.app() != nil else {
            return
        }
        guard let clientID = googleClientID() else {
            return
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
    }

    private func googleClientID() -> String? {
        let candidates = [
            FirebaseApp.app()?.options.clientID,
            Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String
        ]

        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !$0.hasPrefix("YOUR_") && !$0.contains("$(") }
    }

    private func googleSignIn(presenting viewController: UIViewController) async throws -> GIDSignInResult {
        guard FirebaseApp.app() != nil else {
            throw FirebaseIntegrationError.missingConfigurationFile
        }
        guard GIDSignIn.sharedInstance.configuration != nil else {
            throw FirebaseIntegrationError.missingGoogleClientID
        }

        return try await withCheckedThrowingContinuation { continuation in
            GIDSignIn.sharedInstance.signIn(withPresenting: viewController) { result, error in
                if let error {
                    if (error as NSError).code == GIDSignInError.canceled.rawValue {
                        continuation.resume(throwing: FirebaseIntegrationError.signInCancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard let result else {
                    continuation.resume(throwing: FirebaseIntegrationError.signInCancelled)
                    return
                }
                continuation.resume(returning: result)
            }
        }
    }

    private func restorePreviousGoogleSignIn() async throws -> GIDGoogleUser? {
        try await withCheckedThrowingContinuation { continuation in
            GIDSignIn.sharedInstance.restorePreviousSignIn { user, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: user)
            }
        }
    }

    private func signInToFirebase(with googleUser: GIDGoogleUser) async throws -> CurrentUser {
        guard let idToken = googleUser.idToken?.tokenString else {
            throw FirebaseIntegrationError.missingGoogleIDToken
        }

        let credential = GoogleAuthProvider.credential(
            withIDToken: idToken,
            accessToken: googleUser.accessToken.tokenString
        )

        let authResult: AuthDataResult = try await withCheckedThrowingContinuation { continuation in
            Auth.auth().signIn(with: credential) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let result else {
                    continuation.resume(throwing: FirebaseIntegrationError.missingGoogleIDToken)
                    return
                }
                continuation.resume(returning: result)
            }
        }
        return CurrentUser(firebaseUser: authResult.user)
    }
}

struct FirestoreSyncBlobRepository: SyncBlobRepository {
    func fetchLatest(uid: String) async throws -> SyncBlobDocument? {
        let snapshot = try await getDocument(uid: uid)
        guard snapshot.exists, let data = snapshot.data() else {
            return nil
        }
        return try decodeDocument(data)
    }

    func save(_ document: SyncBlobDocument, uid: String) async throws {
        let reference = try syncDocument(uid: uid)
        let data = encodeDocument(document)
        try await withCheckedThrowingContinuation { continuation in
            reference.setData(data, merge: false) { error in
                resumeVoid(continuation, error: error)
            }
        }
    }

    func delete(uid: String) async throws {
        let reference = try syncDocument(uid: uid)
        try await withCheckedThrowingContinuation { continuation in
            reference.delete { error in
                resumeVoid(continuation, error: error)
            }
        }
    }

    private func getDocument(uid: String) async throws -> DocumentSnapshot {
        let reference = try syncDocument(uid: uid)
        return try await withCheckedThrowingContinuation { continuation in
            reference.getDocument { snapshot, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let snapshot else {
                    continuation.resume(throwing: FirebaseIntegrationError.invalidSyncDocument("Missing document snapshot."))
                    return
                }
                continuation.resume(returning: snapshot)
            }
        }
    }

    private func syncDocument(uid: String) throws -> DocumentReference {
        guard FirebaseApp.app() != nil else {
            throw FirebaseIntegrationError.missingConfigurationFile
        }
        return Firestore.firestore()
            .collection("users")
            .document(uid)
            .collection("syncData")
            .document("latest")
    }

    private func encodeDocument(_ document: SyncBlobDocument) -> [String: Any] {
        [
            "encryptedBlob": document.encryptedBlob,
            "salt": document.salt,
            "kdf": document.kdf,
            "kdfIterations": document.kdfIterations,
            "schemaVersion": document.schemaVersion,
            "lastUpdated": Timestamp(date: document.lastUpdated)
        ]
    }

    private func decodeDocument(_ data: [String: Any]) throws -> SyncBlobDocument {
        guard let encryptedBlob = data["encryptedBlob"] as? String else {
            throw FirebaseIntegrationError.invalidSyncDocument("Missing encryptedBlob.")
        }
        guard let salt = data["salt"] as? String else {
            throw FirebaseIntegrationError.invalidSyncDocument("Missing salt.")
        }
        guard let kdf = data["kdf"] as? String else {
            throw FirebaseIntegrationError.invalidSyncDocument("Missing kdf.")
        }
        guard let kdfIterations = data["kdfIterations"] as? Int else {
            throw FirebaseIntegrationError.invalidSyncDocument("Missing kdfIterations.")
        }
        guard let schemaVersion = data["schemaVersion"] as? Int else {
            throw FirebaseIntegrationError.invalidSyncDocument("Missing schemaVersion.")
        }
        let lastUpdated = try decodeDate(data["lastUpdated"])

        return SyncBlobDocument(
            encryptedBlob: encryptedBlob,
            salt: salt,
            kdf: kdf,
            kdfIterations: kdfIterations,
            schemaVersion: schemaVersion,
            lastUpdated: lastUpdated
        )
    }

    private func decodeDate(_ value: Any?) throws -> Date {
        if let timestamp = value as? Timestamp {
            return timestamp.dateValue()
        }
        if let date = value as? Date {
            return date
        }
        throw FirebaseIntegrationError.invalidSyncDocument("Missing lastUpdated.")
    }

    private func resumeVoid(
        _ continuation: CheckedContinuation<Void, any Error>,
        error: Error?
    ) {
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}

extension CurrentUser {
    init(firebaseUser: FirebaseAuth.User) {
        self.init(
            uid: firebaseUser.uid,
            displayName: firebaseUser.displayName ?? firebaseUser.email ?? "Google User",
            email: firebaseUser.email ?? "",
            avatarURL: firebaseUser.photoURL
        )
    }
}

@MainActor
enum PresentingViewControllerProvider {
    static func current() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes
            .flatMap(\.windows)
            .first { $0.isKeyWindow }

        return topViewController(from: window?.rootViewController)
    }

    private static func topViewController(from viewController: UIViewController?) -> UIViewController? {
        if let navigation = viewController as? UINavigationController {
            return topViewController(from: navigation.visibleViewController)
        }
        if let tab = viewController as? UITabBarController {
            return topViewController(from: tab.selectedViewController)
        }
        if let presented = viewController?.presentedViewController {
            return topViewController(from: presented)
        }
        return viewController
    }
}
