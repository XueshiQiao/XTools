import Foundation
import Security

/// What the OS can prove about a binary, computed locally.
///
/// This is the ONLY trustworthy identity in the whole payload. A process's name,
/// path, bundle id and argv are all attacker-controlled strings — anyone can name
/// a binary `Google Chrome Helper` and put it anywhere. A Developer ID signature
/// cannot be forged: "signed by Google LLC, Team ID EQHXZ8M8AV" answers the
/// question the user is actually asking, most of the time, all by itself.
///
/// So the prompt is built to let THIS dominate, and the model is told that
/// everything else is self-reported.
struct CodeSignature: Equatable {

    enum Verdict: Equatable {
        /// Signed by Apple itself (the platform binaries in /System, /usr/…).
        case appleSystem
        /// Signed with a Developer ID certificate — a third-party developer whose
        /// identity Apple has verified.
        case developerID(team: String?, name: String?)
        /// Signed, but not with a Developer ID (ad-hoc, self-signed, or a Mac App
        /// Store / development certificate).
        case otherSigned(name: String?)
        /// No signature at all.
        case unsigned
        /// A signature EXISTS but does not verify — most importantly a binary that
        /// was modified after signing (`errSecCSSignatureFailed`). Deliberately
        /// distinct from `unreadable` ("we couldn't look"): here we looked, and it
        /// is broken — a much stronger signal, and a worse one than `unsigned`.
        case invalidSignature(OSStatus)
        /// The binary could not be read (permission, or it is gone).
        case unreadable(String)
    }

    let verdict: Verdict
    /// Certificate chain leaf → root, as human-readable names.
    let authorities: [String]
    let teamID: String?
    let signingID: String?
    /// Passed Apple's notarization check. nil when the check could not be run.
    let isNotarized: Bool?

    /// Short label for the facts panel. Deterministic — never from a model.
    var badge: String {
        switch verdict {
        case .appleSystem:            return L("processes.sign.apple")
        case .developerID(_, let n):  return String(format: L("processes.sign.devid"), n ?? "?")
        case .otherSigned:            return L("processes.sign.other")
        case .unsigned:               return L("processes.sign.unsigned")
        case .invalidSignature:       return L("processes.sign.invalid")
        case .unreadable:             return L("processes.sign.unreadable")
        }
    }

    /// UNSIGNED and BROKEN signatures are the warnings. "Not Apple" is not
    /// suspicious — most of what people run is not Apple.
    var isWarning: Bool {
        switch verdict {
        case .unsigned, .invalidSignature: return true
        default:                           return false
        }
    }
}

/// Reads code signatures with the public Security framework — no entitlement, no
/// privilege, no shelling out. Slow enough (a large Electron bundle can take
/// seconds) that it must never run on the main thread or per-row.
enum CodeSignInspector {

    private static let log = FileLog("Processes")

    static func inspect(path: String) -> CodeSignature {
        let url = URL(fileURLWithPath: path) as CFURL
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url, [], &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            return CodeSignature(verdict: .unreadable("SecStaticCodeCreateWithPath \(createStatus)"),
                                 authorities: [], teamID: nil, signingID: nil, isNotarized: nil)
        }

        // Is it signed at all? errSecCSUnsigned is the definitive "no".
        let validity = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: 0), nil)
        if validity == errSecCSUnsigned {
            return CodeSignature(verdict: .unsigned, authorities: [],
                                 teamID: nil, signingID: nil, isNotarized: nil)
        }
        // Anything else short of SUCCESS means a signature exists but does NOT
        // verify — above all errSecCSSignatureFailed: a binary MODIFIED after it
        // was signed. This must never fall through to the chain read below: the
        // certificate chain names whoever signed the ORIGINAL bytes, and reporting
        // it would badge a tampered binary as validly Developer-ID-signed — the one
        // piece of evidence the AI prompt is told to trust above everything else
        // (HR2). A broken signature is a stronger warning than no signature.
        guard validity == errSecSuccess else {
            log.warn("code signature INVALID for pid-selected binary (status \(validity))")
            return CodeSignature(verdict: .invalidSignature(validity), authorities: [],
                                 teamID: nil, signingID: nil, isNotarized: false)
        }

        var infoRef: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        guard SecCodeCopySigningInformation(code, flags, &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any] else {
            return CodeSignature(verdict: .unreadable("SecCodeCopySigningInformation failed"),
                                 authorities: [], teamID: nil, signingID: nil, isNotarized: nil)
        }

        let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String
        let signingID = info[kSecCodeInfoIdentifier as String] as? String

        var authorities: [String] = []
        if let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate] {
            for cert in certs {
                if let summary = SecCertificateCopySubjectSummary(cert) as String? {
                    authorities.append(summary)
                }
            }
        }

        let verdict = classify(authorities: authorities, teamID: teamID)
        let notarized: Bool? = {
            // Apple's own platform binaries are not "notarized" — notarization is
            // the third-party pipeline. Asking the question of them is meaningless,
            // and a `false` there would read as a warning it is not.
            if case .appleSystem = verdict { return nil }
            return checkNotarized(code)
        }()

        return CodeSignature(verdict: verdict, authorities: authorities,
                             teamID: teamID, signingID: signingID, isNotarized: notarized)
    }

    private static func classify(authorities: [String], teamID: String?) -> CodeSignature.Verdict {
        // Apple's platform binaries are signed by "Software Signing", chaining to
        // "Apple Root CA". This is an identity claim the OS proves, NOT a path check
        // — a binary sitting in /System that isn't Apple-signed must not pass.
        if authorities.contains(where: { $0 == "Software Signing" || $0 == "Apple Code Signing Certification Authority" }) {
            return .appleSystem
        }
        if let leaf = authorities.first, leaf.hasPrefix("Developer ID Application:") {
            // "Developer ID Application: Google LLC (EQHXZ8M8AV)" → "Google LLC"
            var name = String(leaf.dropFirst("Developer ID Application:".count))
                .trimmingCharacters(in: .whitespaces)
            if let paren = name.range(of: " (", options: .backwards) {
                name = String(name[name.startIndex..<paren.lowerBound])
            }
            return .developerID(team: teamID, name: name)
        }
        if authorities.isEmpty { return .unsigned }
        return .otherSigned(name: authorities.first)
    }

    /// `notarized` is a real code-signing requirement string; asking the OS is the
    /// only honest way to answer this. Returns nil if the check itself failed for a
    /// reason other than "not notarized".
    private static func checkNotarized(_ code: SecStaticCode) -> Bool? {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("notarized" as CFString, [], &requirement) == errSecSuccess,
              let req = requirement else { return nil }
        let status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: 0), req)
        if status == errSecSuccess { return true }
        if status == errSecCSReqFailed { return false }
        return nil   // couldn't tell — say so, don't guess
    }
}
