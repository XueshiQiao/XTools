import AppKit

/// Owns the ordered list of `SelectionStrategy` and runs the fallback chain.
///
/// This is the ONE place the fallback policy lives. Both Easydict and
/// SelectedTextKit scatter their fallback logic across two or three places (a
/// hardcoded `.auto` chain *and* an ordered-array runner *and* the app on top);
/// we deliberately keep it in a single object so reordering or adding a strategy
/// is a one-line change with no duplicated policy.
///
/// Rules (the consensus all three reference projects converged on):
///  - first strategy returning a non-empty string wins;
///  - an empty result is treated as failure → try the next;
///  - a thrown `.permissionDenied` is fatal → abort the whole chain.
final class SelectionResolver {

    private static let log = FileLog("PopBar.Resolver")

    private let strategies: [SelectionStrategy]

    init(strategies: [SelectionStrategy]) {
        self.strategies = strategies
    }

    /// Try each applicable strategy in order; return the first success or nil.
    func resolve(_ context: SelectionContext) async -> SelectionResult? {
        for strategy in strategies where strategy.canHandle(context) {
            do {
                if let result = try await strategy.selectedText(context), !result.text.isEmpty {
                    Self.log.info("resolved \(result.text.count) char(s) via \(strategy.id.rawValue)")
                    return result
                }
            } catch let error as SelectionError where error.isFatal {
                Self.log.warn("permission denied from \(strategy.id.rawValue) — aborting chain")
                return nil
            } catch {
                continue
            }
        }
        return nil
    }
}
