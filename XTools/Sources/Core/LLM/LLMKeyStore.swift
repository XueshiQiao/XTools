import Foundation

/// App-level store for the LLM API keys: **one key per provider** in the Keychain
/// (service `me.xueshi.xtools.llm`, account `llm-key-<provider>`), so any tool can
/// reach any provider you've configured. This is shared infra (Core), not owned by
/// any single tool — it is the One Source of Truth for the keys.
///
/// A one-time, idempotent MIGRATION copies any keys the user previously saved under
/// PopBar's old service (`me.xueshi.xtools.popbar`) into the new service, so
/// promoting the LLM stack from a tool to an app-level service never loses a key.
/// The old entries are READ and copied, then removed only after a successful copy;
/// a `UserDefaults` flag makes the whole pass run at most once.
struct LLMKeyStore {

    private static let log = FileLog("LLM.Keys")

    /// New app-level service (the One Source of Truth going forward).
    static let service = "me.xueshi.xtools.llm"
    /// Legacy PopBar-scoped service we migrate FROM (read-only after migration).
    private static let legacyService = "me.xueshi.xtools.popbar"
    private static let migrationFlag = "xtools.llm.keyMigratedFromPopBarV1"

    private static let keychain = KeychainStore(service: service)
    private static func keyAccount(_ provider: String) -> String { "llm-key-\(provider)" }

    // MARK: - Read / write (per provider)

    /// The stored key for a provider, or "" if none. Never throws — absence is "".
    func key(for provider: String) -> String {
        Self.keychain.get(Self.keyAccount(provider)) ?? ""
    }

    func hasKey(for provider: String) -> Bool {
        !key(for: provider).isEmpty
    }

    /// Store (or replace) a provider's key. Returns nil on success, else a message.
    @discardableResult
    func save(_ key: String, for provider: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            try Self.keychain.set(trimmed, account: Self.keyAccount(provider))
            Self.log.info("API key saved for \(provider)")
            return nil
        } catch {
            Self.log.error("keychain save failed for \(provider): \(error)")
            return "\(error)"
        }
    }

    func clear(for provider: String) {
        Self.keychain.remove(Self.keyAccount(provider))
        Self.log.info("API key cleared for \(provider)")
    }

    /// The set of providers that currently have a key — drives the settings UI.
    func keyedProviders() -> Set<String> {
        var set = Set<String>()
        for p in LLMConfig.providers where hasKey(for: p) { set.insert(p) }
        return set
    }

    // MARK: - Migration (PopBar service → app service)

    /// One-time, idempotent. For each provider, if the new service has no key but
    /// the old PopBar service does, COPY it over (read old → write new). Only after
    /// a verified successful copy is the old entry removed, so an interrupted run
    /// can't drop a key. A `UserDefaults` flag prevents re-running, and the
    /// per-provider "new is empty / old exists" guard makes a stray re-run a no-op
    /// anyway.
    static func migrateFromPopBarIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: migrationFlag) else { return }

        let legacy = KeychainStore(service: legacyService)
        var migrated = 0
        // If ANY pending legacy key failed to copy/verify, we must NOT mark the
        // migration complete — otherwise the next launch returns early and those
        // keys stay stranded under the old service forever. Leave the flag unset so
        // the migration retries; the per-provider "new empty / old exists" guards
        // make a retry idempotent (already-migrated keys are skipped).
        var anyFailed = false

        // Copy `old → new` if present, verify it landed, then remove the source.
        // Returns false on a copy/verify failure (source left intact).
        func migrate(account: String, label: String) -> Bool {
            if let existing = keychain.get(account), !existing.isEmpty { return true }  // already there
            guard let old = legacy.get(account), !old.isEmpty else { return true }      // nothing to do
            do {
                try keychain.set(old, account: account)
                guard keychain.get(account) == old else {
                    log.error("migration verify failed for \(label) — leaving old key in place")
                    return false
                }
                legacy.remove(account)
                migrated += 1
                return true
            } catch {
                log.error("migration copy failed for \(label): \(error) — leaving old key in place")
                return false
            }
        }

        for provider in LLMConfig.providers {
            if !migrate(account: keyAccount(provider), label: provider) { anyFailed = true }
        }

        // Also migrate PopBar's even-older single-key entry (`llm-api-key`), which
        // PopBar itself would have moved onto its saved default provider. If PopBar
        // already ran its own migration this is absent; if not, fold it onto the SAME
        // provider PopBar would have used — its saved `popbar.llm.provider` default
        // (falling back to deepseek) — so the key lands where `LLMSettingsStore`
        // restores the default, not always deepseek.
        // (Its source account name differs from any target account, so it can't go
        // through `migrate(account:)` above — it needs an explicit source→target.)
        let legacySingleAccount = "llm-api-key"
        if let single = legacy.get(legacySingleAccount), !single.isEmpty {
            let legacyDefaultProvider = d.string(forKey: "popbar.llm.provider") ?? "deepseek"
            let target = keyAccount(legacyDefaultProvider)
            if (keychain.get(target) ?? "").isEmpty {
                do {
                    try keychain.set(single, account: target)
                    if keychain.get(target) == single {
                        legacy.remove(legacySingleAccount)
                        migrated += 1
                    } else {
                        log.error("migration verify failed for legacy-single key — leaving in place")
                        anyFailed = true
                    }
                } catch {
                    log.error("migration copy failed for legacy-single key: \(error) — leaving in place")
                    anyFailed = true
                }
            }
        }

        if migrated > 0 { log.info("migrated \(migrated) LLM key(s) from PopBar service") }
        // Only seal the migration when nothing was left behind; otherwise retry next launch.
        if !anyFailed { d.set(true, forKey: migrationFlag) }
        else { log.info("migration incomplete — will retry on next launch") }
    }
}
