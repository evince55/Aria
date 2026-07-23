import Combine
import Foundation
import StoreKit

/// Owns the one-time "Aria Pro" unlock: product loading, purchase, restore,
/// and the `isPro` entitlement the rest of the app gates Pro features on.
///
/// StoreKit 2, non-consumable. The last-verified entitlement is cached in
/// `UserDefaults` so Pro features unlock instantly at launch and keep working
/// offline; StoreKit's on-device entitlement cache is re-checked on every
/// launch and a long-lived `Transaction.updates` listener picks up purchases,
/// Ask-to-Buy approvals, and refunds while the app runs.
///
/// Entitlement policy: `refreshEntitlement()` only *grants* (a transient empty
/// answer from StoreKit must never lock out a paying user); revocation flows
/// exclusively through the updates listener, which sees the revoked
/// transaction (`revocationDate != nil`) after a refund.
///
/// Local testing without App Store Connect: select `Aria.storekit` in the
/// scheme's Run options (StoreKit Configuration) and purchases run entirely
/// on-device against the local config.
final class ProStore: ObservableObject {
    /// App Store product id for the lifetime Pro unlock (non-consumable).
    /// Must match the product configured in App Store Connect / `Aria.storekit`.
    static let proProductID = "com.chaitea321.aria.pro"
    /// UserDefaults key for the cached entitlement.
    static let cacheKey = "aria_pro_unlocked"

    /// True when the Pro unlock is owned. Gate Pro features on this.
    @Published private(set) var isPro: Bool
    /// The store product, once loaded — supplies the localized price.
    @Published private(set) var product: Product?
    /// True while a purchase is running; disables the buy button.
    @Published private(set) var purchaseInFlight = false
    /// Last user-visible store error; the paywall surfaces + clears it.
    @Published var lastError: String?

    private let defaults: UserDefaults
    private var updatesTask: Task<Void, Never>?

    /// `autostart: false` skips all StoreKit calls — used by unit tests, which
    /// drive entitlement state through `applyEntitlement` directly.
    init(defaults: UserDefaults = .standard, autostart: Bool = true) {
        self.defaults = defaults
        self.isPro = defaults.bool(forKey: Self.cacheKey)
        guard autostart else { return }
        updatesTask = Task { [weak self] in await self?.listenForTransactions() }
        Task { [weak self] in
            await self?.loadProduct()
            await self?.refreshEntitlement()
        }
    }

    deinit { updatesTask?.cancel() }

    // MARK: - Entitlement

    /// Applies a verified entitlement decision and persists it. Internal so
    /// tests can drive state without the StoreKit daemon.
    func applyEntitlement(_ unlocked: Bool) {
        isPro = unlocked
        defaults.set(unlocked, forKey: Self.cacheKey)
    }

    /// Re-checks StoreKit's current entitlements. Grant-only by design — see
    /// the type doc for why this never revokes.
    func refreshEntitlement() async {
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == Self.proProductID,
               transaction.revocationDate == nil {
                applyEntitlement(true)
                return
            }
        }
    }

    // MARK: - Store

    func loadProduct() async {
        do {
            product = try await Product.products(for: [Self.proProductID]).first
        } catch {
            // Paywall shows a retry state when the product is nil; keep the
            // error quiet unless the user explicitly acts.
            product = nil
        }
    }

    func purchase() async {
        guard !purchaseInFlight else { return }
        purchaseInFlight = true
        defer { purchaseInFlight = false }

        if product == nil { await loadProduct() }
        guard let product else {
            lastError = "Couldn't reach the App Store. Check your connection and try again."
            return
        }

        do {
            switch try await product.purchase() {
            case .success(let verification):
                let transaction = try Self.checkVerified(verification)
                applyEntitlement(transaction.revocationDate == nil)
                await transaction.finish()
            case .userCancelled:
                break
            case .pending:
                // Ask to Buy — the updates listener completes it when approved.
                lastError = "Purchase pending approval."
            @unknown default:
                break
            }
        } catch {
            lastError = "Purchase failed: \(error.localizedDescription)"
        }
    }

    /// Re-syncs with the App Store (sign-in sheet may appear), then re-checks
    /// entitlements. This is the "Restore Purchases" button.
    func restore() async {
        do {
            try await AppStore.sync()
        } catch {
            // User cancelled the sign-in sheet — nothing to surface.
            return
        }
        await refreshEntitlement()
    }

    // MARK: - Private

    private func listenForTransactions() async {
        for await result in Transaction.updates {
            guard case .verified(let transaction) = result,
                  transaction.productID == Self.proProductID else { continue }
            // Purchases/approvals grant; refunds (revocationDate set) revoke.
            applyEntitlement(transaction.revocationDate == nil)
            await transaction.finish()
        }
    }

    private static func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let safe): return safe
        case .unverified(_, let error): throw error
        }
    }
}
