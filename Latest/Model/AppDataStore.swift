//
//  AppCollection.swift
//  Latest
//
//  Created by Max Langer on 15.08.18.
//  Copyright © 2018 Max Langer. All rights reserved.
//

import Foundation

/// The collection handling the apps
/// This structure supports the following states:
/// - All apps with updates available
/// - All installed apps, separated from the ones with updates through sections
/// - A filtered list of apps based on a given filter string
class AppDataStore {
	
	// MARK: - Filtering
	
	/// The collection holding all apps that have been found.
	private var apps = Set<AppBundle>()
	
	/// A subset of apps that can be updated. Ignored apps are not part of this list.
	var updateableApps: [AppBundle] {
		return self.apps.filter({ $0.updateAvailable && !self.isAppIgnored($0) })
	}
	
	/// The user-facable, sorted and filtered list of apps and sections. Observers of the data store will be notified, when this list changes.
	private(set) var filteredApps = [Entry]() {
		didSet {
			self.notifyObservers(oldValue: oldValue, newValue: self.filteredApps)
		}
	}
	
	/// The query after which apps can be filtered
	var filterQuery: String? {
		didSet {
			// Cleanup empty filter queries
			if self.filterQuery?.isEmpty ?? false {
				self.filterQuery = nil
			}
			
			// Always lowercase query
			self.filterQuery = self.filterQuery?.lowercased()
			self.filterApps()
		}
	}
	
	/// Sorts and filters all available apps based on the given filter criteria.
	private func filterApps() {
		var visibleApps = self.apps
		let ignoredApps = visibleApps.filter({ self.ignoredAppIdentifiers.contains($0.bundleIdentifier) })
		
		// Filter installed updates
		if !self.showInstalledUpdates {
			visibleApps = visibleApps.filter({ $0.updateAvailable })
		}
		
		// Apply filter query
		if let filterQuery = self.filterQuery {
			visibleApps = visibleApps.filter({ $0.name.lowercased().contains(filterQuery) })
		}
		
		// Filter ignored apps
		if !self.showIgnoredUpdates {
			visibleApps = visibleApps.filter({ !ignoredApps.contains($0) })
		}
		
		// Sort apps
		var filteredApps = visibleApps.sorted(by: { (app1, app2) -> Bool in
			let ignored1 = ignoredApps.contains(app1)
			let ignored2 = ignoredApps.contains(app2)
			
			if ignored1 != ignored2 {
				return ignored2
			}
			
			if !(ignored2 || ignored1) && app1.updateAvailable != app2.updateAvailable {
				return app1.updateAvailable
			}
			
			return app1.name.lowercased() < app2.name.lowercased()
		}).map({ Entry.app($0) })
		
		// Add sections
		if self.showInstalledUpdates || self.showIgnoredUpdates {
			if self.showIgnoredUpdates && !ignoredApps.isEmpty {
				filteredApps.insert(.section(.ignored), at: filteredApps.count - ignoredApps.count)
			}
			
			if self.showInstalledUpdates && self.apps.count > self.countOfAvailableUpdates {
				filteredApps.insert(.section(.installed), at: self.countOfAvailableUpdates)
			}

			if self.countOfAvailableUpdates > 0 {
				filteredApps.insert(.section(.updateAvailable), at: 0)
			}
		}
		
		self.filteredApps = filteredApps
	}
	
	/// The cached count of apps with updates available
	private(set) var countOfAvailableUpdates: Int = 0
	
    /// Adds a new app to the collection
	func update(_ app: AppBundle) {
		if let oldApp = self.apps.first(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
			self.apps.remove(oldApp)
			self.pendingApps?.remove(oldApp)
			
			self.countOfAvailableUpdates -= oldApp.updateAvailable ? 1 : 0
		}
		
        self.apps.insert(app)
		
		self.countOfAvailableUpdates += app.updateAvailable ? 1 : 0
    }
	
	
	// MARK: - Accessors
	
    /// Whether installed apps should be visible
	var showInstalledUpdates = false {
		didSet {
			self.filterApps()
		}
	}
	
	/// Whether ignored apps should be visible
	var showIgnoredUpdates = false {
		didSet {
			self.filterApps()
		}
	}
	
	/// Returns the app at the given index, if any.
	func app(at index: Int) -> AppBundle? {
		if case .app(let app) = self.filteredApps[index] {
			return app
		}
		
		return nil
	}
	
    /// Returns whether there is a section at the given index
    func isSectionHeader(at index: Int) -> Bool {
		if case .section(_) = self.filteredApps[index] {
			return true
		}
		
		return false
    }
	
	
	// MARK: - Ignoring Apps
	
	/// The key for storing a list of ignored apps.
	private static let IgnoredAppsKey = "IgnoredAppsKey"

	/// Whether the given app is ignored.
	func isAppIgnored(_ app: AppBundle) -> Bool {
		return self.ignoredAppIdentifiers.contains(app.bundleIdentifier)
	}
	
	/// Sets the ignored state of the given app.
	func setIgnored(_ ignored: Bool, for app: AppBundle) {
		var ignoredApps = self.ignoredAppIdentifiers
		
		if ignored {
			ignoredApps.insert(app.bundleIdentifier)
		} else {
			ignoredApps.remove(app.bundleIdentifier)
		}

		UserDefaults.standard.set(Array(ignoredApps), forKey: Self.IgnoredAppsKey)
		
		self.updateCountOfAvailableApps()
		self.filterApps()
	}
	
	/// Returns the identifiers of ignored apps.
	private var ignoredAppIdentifiers: Set<String> {
		return Set((UserDefaults.standard.array(forKey: Self.IgnoredAppsKey) as? [String]) ?? [])
	}
	
	
	// MARK: - Update Process
	
	/// A temporare set of all apps that need to be updated in the current update pass.
	private var pendingApps: Set<AppBundle>?
	
	/// Begins one update pass. Every app in the data store has to be marked as updated, otherwise it will be removed on `endUpdates`.
	func beginUpdates() {
		guard self.pendingApps == nil else { fatalError("Update is currently running.") }
		
		// Set our current state as pending
		self.pendingApps = self.apps
	}
	
	/// Ends current the update pass.
	func endUpdates() {
		guard let pendingApps = self.pendingApps else { fatalError("No update was initiated previously.") }
		
		// Remove all apps that have not been updated
		self.apps.subtract(pendingApps)
		self.pendingApps = nil
	
		self.updateCountOfAvailableApps()
		self.filterApps()
	}
	
	/// Updates the count of all available apps.
	private func updateCountOfAvailableApps() {
		self.countOfAvailableUpdates = self.apps.filter({ $0.updateAvailable && !self.ignoredAppIdentifiers.contains($0.bundleIdentifier) }).count
	}
	
	
	// MARK: - Observer Handling
	
	/// The handler for notifying observers about changes to the update state.
	typealias ObserverHandler = (_ oldValue: [Entry], _ newValue: [Entry]) -> Void

	/// A mapping of observers assotiated with apps.
	private var observers = [NSObject: ObserverHandler]()
	
	/// Adds the observer if it is not already registered.
	func addObserver(_ observer: NSObject, handler: @escaping ObserverHandler) {
		guard !self.observers.keys.contains(observer) else { return }
		self.observers[observer] = handler
		
		// Call handler immediately to propagate initial state
		handler(self.filteredApps, self.filteredApps)
	}
	
	/// Remvoes the observer.
	func removeObserver(_ observer: NSObject, for app: AppBundle) {
		self.observers.removeValue(forKey: observer)
	}
		
	/// Notifies observers about state changes.
	private func notifyObservers(oldValue: [Entry], newValue: [Entry]) {
		DispatchQueue.main.async {
			self.observers.forEach { (key: NSObject, handler: ObserverHandler) in
				handler(oldValue, newValue)
			}
		}
	}

}

extension AppDataStore {
	
	/// Defines one entry in the filtered update.
	enum Entry: Equatable, Hashable {
		
		/// Represents one app in the list.
		case app(AppBundle)
		
		/// Represents one section header in the list.
		case section(Section)
		
	}
	
	/// Defines section headers.
	enum Section {
		
		/// The section containing apps that have an update available.
		case updateAvailable
		
		/// The section containing all apps that both don't have updates and are not ignored.
		case installed
		
		/// The section containing apps that are ignored.
		case ignored
		
	}
}
