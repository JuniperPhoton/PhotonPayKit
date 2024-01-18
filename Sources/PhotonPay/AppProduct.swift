// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation
import StoreKit
import OSLog
import SwiftUI

@available(iOS 15.0, macOS 12.0, *)
public struct ResolvedProduct {
    public let product: Product
    public let isActive: Bool
}

private let storeLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "PhotonUtility",
    category: "store"
)

public protocol AppProductDelegate: AnyObject {
    func onProductVerified(id: String)
    func onProductRevocated(id: String)
    func onProductExpired(id: String)
}

/// Provides easy access to the in-app purchase products.
///
/// You initialize this class by passing your identifiers, and the blocks to handle transcation changes.
///
/// It's an ``ObservableObject`` and it provides ``products`` and ``isLoading`` to be observed.
///
/// You use ``loadProducts()`` to load all products of your identifiers. Then you observe the changes of ``products`` to update your UI.
/// To restore App Store, use ``restore()``.
///
/// To purchase a product, use ``purchase(product:)``.
@available(iOS 15.0, macOS 12.0, *)
public class AppProduct: ObservableObject {
    private let observer: TransactionObserver
    
    /// Resolved products to be observed.
    @Published
    public var products: [ResolvedProduct] = []
    
    /// Observe if it's loading or not.
    /// This will be true on loading products or purchasing a product.
    ///
    /// You can observe this to disable buttons or show loading UI.
    @Published
    public var isLoading = false
    
    /// The identifiers you pass in the initializer.
    public let identifiers: [String]
    
    public private(set) var transaction: SwiftUI.Transaction = .init()
    
    private weak var delegate: AppProductDelegate?
    
    /// Initialize using your own identifiers and blocks to handle transcation events.
    /// - parameter identifiers: your product identifiers in an array
    /// - parameter onProductVerified: the block to be invoked when a product is verfied
    /// - parameter onProductRevocated: the block to be invoked when a product is revocated
    public init(identifiers: [String]) {
        self.identifiers = identifiers
        self.observer = TransactionObserver(identifiers: identifiers)
    }
    
    public func setTransaction(_ transaction: SwiftUI.Transaction) {
        self.transaction = transaction
    }
    
    public func setDelegate(delegate: AppProductDelegate?) {
        self.delegate = delegate
        self.observer.delegate = delegate
    }
    
    @MainActor
    public func restore() async throws {
        withTransaction(transaction) {
            self.isLoading = true
        }
        
        defer {
            withTransaction(transaction) {
                self.isLoading = false
            }
        }
        
        storeLogger.log("start restore")
        
        do {
            try await AppStore.sync()
            await loadProducts()
            storeLogger.log("finish restore")
        } catch {
            storeLogger.log("error on restore \(error)")
            throw error
        }
    }
    
    @MainActor
    public func loadProducts() async {
        withTransaction(transaction) {
            self.isLoading = true
        }
        
        do {
            let appProducts = try await Product.products(for: identifiers)
            storeLogger.log("products are \(appProducts.count)")
            
            let products = await refreshProductTranscation(products: appProducts)
            withTransaction(transaction) {
                self.products = products
                self.isLoading = false
            }
        } catch {
            storeLogger.log("error on getting products \(error)")
            withTransaction(transaction) {
                self.isLoading = false
            }
        }
    }
    
    @MainActor
    public func purchase(product: Product) async throws {
        do {
            storeLogger.log("begin purchase \(product.displayName)")
            
            withTransaction(transaction) {
                isLoading = true
            }
            
            let result = try await product.purchase(options: [])
            switch result {
            case .success(let verification):
                //Check whether the transaction is verified. If it isn't,
                //this function rethrows the verification error.
                let transaction = checkVerified(verification)
                
                if let transaction = transaction {
                    storeLogger.log("purchase success")
                    await loadProducts()
                    await transaction.finish()
                    storeLogger.log("finish transaction \(transaction.id)")
                } else {
                    storeLogger.log("purchase error, not verififed")
                }
            case .userCancelled:
                storeLogger.log("user cancelled")
            case .pending:
                storeLogger.log("purchase pending...")
            @unknown default:
                storeLogger.log("purchase unknown result...")
            }
            
            storeLogger.log("end purchase \(product.displayName)")
            
            withTransaction(transaction) {
                self.isLoading = false
            }
        } catch {
            storeLogger.log("error on purchasing products \(error)")
            
            withTransaction(transaction) {
                self.isLoading = false
            }
            
            throw error
        }
    }
    
    private func checkVerified<T>(_ result: VerificationResult<T>) -> T? {
        //Check whether the JWS passes StoreKit verification.
        switch result {
        case .unverified:
            //StoreKit parses the JWS, but it fails verification.
            return nil
        case .verified(let safe):
            //The result is verified. Return the unwrapped value.
            return safe
        }
    }
    
    private func refreshProductTranscation(products: [Product]) async -> [ResolvedProduct] {
        var resolved: [ResolvedProduct] = []
        
        storeLogger.log("refreshProductTranscation")
        
        for product in products {
            if let transaction = await product.currentEntitlement {
                let handledTransaction = observer.handle(updatedTransaction: transaction)
                resolved.append(ResolvedProduct(product: product, isActive: handledTransaction?.isActive == true))
            } else {
                storeLogger.error("no currentEntitlement for \(product.id)")
                delegate?.onProductRevocated(id: product.id)
                resolved.append(ResolvedProduct(product: product, isActive: false))
            }
        }
        
        return resolved
    }
}

@available(iOS 15.0, macOS 12.0, *)
fileprivate final class TransactionObserver {
    var updatesTask: Task<Void, Never>? = nil
    let identifiers: [String]
    weak var delegate: AppProductDelegate?
    
    init(identifiers: [String]) {
        self.identifiers = identifiers
        newTransactionListenerTask()
    }
    
    deinit {
        // Cancel the update handling task when you deinitialize the class.
        updatesTask?.cancel()
        storeLogger.log("cancel TransactionObserver")
    }
    
    private func newTransactionListenerTask() {
        updatesTask = Task(priority: .background) {
            storeLogger.log("begin observe updates")
            
            // Any unfinished transactions will be emitted from `updates` when you first iterate the sequence.
            // Thus we need not to iterate the unfinished sequences.
            // When there are unfinished updates, the order of updates will be ascent by date.
            for await verificationResult in Transaction.updates {
                storeLogger.log("handle updates")
                if let result = self.handle(updatedTransaction: verificationResult) {
                    await result.transaction.finish()
                    storeLogger.log("finish transaction \(result.transaction.id)")
                }
            }
        }
    }
    
    @discardableResult
    func handle(updatedTransaction verificationResult: VerificationResult<StoreKit.Transaction>) -> ResolvedTransactionResult? {
        guard case .verified(let transaction) = verificationResult else {
            // Ignore unverified transactions.
            storeLogger.log("handle but verificationResult is verified")
            return nil
        }
        
        if !identifiers.contains(transaction.productID) {
            return nil
        }
        
        storeLogger.log("handle updatedTransaction, expirationDate: \(String(describing: transaction.expirationDate)) for \(transaction.productID)")
        
        if let _ = transaction.revocationDate {
            // Remove access to the product identified by transaction.productID.
            // Transaction.revocationReason provides details about
            // the revoked transaction.
            if #available(iOS 15.4, macOS 12.3, *) {
                storeLogger.log("revocated, reasons: \(String(describing: transaction.revocationReason?.localizedDescription))")
            }
            delegate?.onProductRevocated(id: transaction.productID)
            return .init(transaction: transaction, isActive: false)
        } else if let expirationDate = transaction.expirationDate,
                  expirationDate < Date() {
            // Do nothing, this subscription is expired.
            delegate?.onProductExpired(id: transaction.productID)
            return .init(transaction: transaction, isActive: false)
        } else if transaction.isUpgraded {
            // Do nothing, there is an active transaction
            // for a higher level of service.
            let productId = transaction.productID
            storeLogger.log("transaction.isUpgraded, provide access to \(productId)")
            delegate?.onProductVerified(id: productId)
            return .init(transaction: transaction, isActive: true)
        } else {
            // Provide access to the product identified by
            // transaction.productID.
            let productId = transaction.productID
            storeLogger.log("handle updatedTransaction, provide access to \(productId)")
            delegate?.onProductVerified(id: productId)
            return .init(transaction: transaction, isActive: true)
        }
    }
}

private struct ResolvedTransactionResult {
    let transaction: StoreKit.Transaction
    let isActive: Bool
}
