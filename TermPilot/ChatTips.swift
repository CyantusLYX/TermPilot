import SwiftUI
import TipKit

enum VaultIntroTipState {
    static func keychainTip(hostCount: Int, keychainItemCount: Int) -> AddKeychainLoginMethodTip? {
        keychainItemCount == 0 ? AddKeychainLoginMethodTip() : nil
    }

    static func hostTip(hostCount: Int, keychainItemCount: Int) -> AddHostProfileTip? {
        keychainItemCount > 0 && hostCount == 0 ? AddHostProfileTip() : nil
    }
}

struct AddKeychainLoginMethodTip: Tip {
    var title: Text {
        Text("Add a Login Method")
    }

    var message: Text? {
        Text("Create a Keychain password or SSH key before adding a host.")
    }

    var image: Image? {
        Image(systemName: "key.fill")
    }
}

struct AddHostProfileTip: Tip {
    var title: Text {
        Text("Add Your First Host")
    }

    var message: Text? {
        Text("After saving a login method, create a host and link it to that Keychain item.")
    }

    var image: Image? {
        Image(systemName: "server.rack")
    }
}

/// Ordered intro guide for the terminal workspace.
/// Step 1 points at the Raw/Chat mode picker, step 2 at the Diagnose button.
/// Build it in a view as `TipGroup(.ordered) { ModeSwitchTip(); DiagnoseTip() }`.
struct ModeSwitchTip: Tip {
    var title: Text {
        Text("Two Ways to Work")
    }

    var message: Text? {
        Text("Raw is the full terminal. Chat lets the assistant propose commands while the session keeps running.")
    }

    var image: Image? {
        Image(systemName: "rectangle.2.swap")
    }
}

struct DiagnoseTip: Tip {
    var title: Text {
        Text("Quick Diagnosis")
    }

    var message: Text? {
        Text("Ask the assistant for a TL;DR of the current terminal output.")
    }

    var image: Image? {
        Image(systemName: "stethoscope")
    }
}

struct ChatModeReadyTip: Tip {
    var title: Text {
        Text("Chat Mode Is Ready")
    }

    var message: Text? {
        Text("Commands the assistant suggests appear as review cards and never run until you approve them. After a command runs, the assistant reads the output and continues on its own.")
    }

    var image: Image? {
        Image(systemName: "sparkles")
    }
}

struct ProposalReviewTip: Tip {
    static let proposalShown = Tips.Event(id: "proposalShown")

    var title: Text {
        Text("Review Suggested Commands")
    }

    var message: Text? {
        Text("Run executes after your approval. While a command awaits review, the input field sends revision requests; Reject declines and collapses the card.")
    }

    var image: Image? {
        Image(systemName: "checklist")
    }

    var rules: [Rule] {
        #Rule(Self.proposalShown) {
            $0.donations.count >= 1
        }
    }
}
