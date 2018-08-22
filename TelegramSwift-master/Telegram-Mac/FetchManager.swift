import Foundation
import PostboxMac
import TelegramCoreMac
import SwiftSignalKitMac

private struct FetchManagerLocationEntryId: Hashable {
    let location: FetchManagerLocation
    let resourceId: MediaResourceId
    let locationKey: FetchManagerLocationKey
    
    static func ==(lhs: FetchManagerLocationEntryId, rhs: FetchManagerLocationEntryId) -> Bool {
        if lhs.location != rhs.location {
            return false
        }
        if !lhs.resourceId.isEqual(to: rhs.resourceId) {
            return false
        }
        if lhs.locationKey != rhs.locationKey {
            return false
        }
        return true
    }
    
    var hashValue: Int {
        return self.resourceId.hashValue &* 31 &+ self.locationKey.hashValue
    }
}

private final class FetchManagerLocationEntry {
    let id: FetchManagerLocationEntryId
    let episode: Int32
    let resource: MediaResource
    let fetchTag: MediaResourceFetchTag?
    
    var referenceCount: Int32 = 0
    var elevatedPriorityReferenceCount: Int32 = 0
    var userInitiatedPriorityIndices: [Int32] = []
    
    var priorityKey: FetchManagerPriorityKey? {
        if self.referenceCount >= 0 {
            return FetchManagerPriorityKey(locationKey: self.id.locationKey, hasElevatedPriority: self.elevatedPriorityReferenceCount > 0, userInitiatedPriority: userInitiatedPriorityIndices.last)
        } else {
            return nil
        }
    }
    
    init(id: FetchManagerLocationEntryId, episode: Int32, resource: MediaResource, fetchTag: MediaResourceFetchTag?) {
        self.id = id
        self.episode = episode
        self.resource = resource
        self.fetchTag = fetchTag
    }
}

private final class FetchManagerActiveContext {
    var disposable: Disposable?
}

private final class FetchManagerStatusContext {
    var disposable: Disposable?
    var originalStatus: MediaResourceStatus?
    var subscribers = Bag<(MediaResourceStatus) -> Void>()
    
    var hasEntry = false
    
    var isEmpty: Bool {
        return !self.hasEntry && self.subscribers.isEmpty
    }
    
    var combinedStatus: MediaResourceStatus? {
        if let originalStatus = self.originalStatus {
            if originalStatus == .Remote && self.hasEntry {
                return .Fetching(isActive: false, progress: 0.0)
            } else {
                return originalStatus
            }
        } else {
            return nil
        }
    }
}

private final class FetchManagerCategoryContext {
    private let postbox: Postbox
    private let entryCompleted: (FetchManagerLocationEntryId, FetchResourceSourceType) -> Void
    
    private var topEntryIdAndPriority: (FetchManagerLocationEntryId, FetchManagerPriorityKey)?
    private var entries: [FetchManagerLocationEntryId: FetchManagerLocationEntry] = [:]
    
    private var activeContexts: [FetchManagerLocationEntryId: FetchManagerActiveContext] = [:]
    private var statusContexts: [FetchManagerLocationEntryId: FetchManagerStatusContext] = [:]
    
    init(postbox: Postbox, entryCompleted: @escaping (FetchManagerLocationEntryId, FetchResourceSourceType) -> Void) {
        self.postbox = postbox
        self.entryCompleted = entryCompleted
    }
    
    func withEntry(id: FetchManagerLocationEntryId, takeNew: (() -> (MediaResource, MediaResourceFetchTag?, Int32))?, _ f: (FetchManagerLocationEntry) -> Void) {
        let entry: FetchManagerLocationEntry
        let previousPriorityKey: FetchManagerPriorityKey?
        
        if let current = self.entries[id] {
            entry = current
            previousPriorityKey = entry.priorityKey
        } else if let takeNew = takeNew {
            previousPriorityKey = nil
            let (resource, fetchTag, episode) = takeNew()
            entry = FetchManagerLocationEntry(id: id, episode: episode, resource: resource, fetchTag: fetchTag)
            self.entries[id] = entry
        } else {
            return
        }
        
        f(entry)
        
        var removedEntries = false
        
        let updatedPriorityKey = entry.priorityKey
        if previousPriorityKey != updatedPriorityKey {
            if let updatedPriorityKey = updatedPriorityKey {
                if let (topId, topPriority) = self.topEntryIdAndPriority {
                    if updatedPriorityKey < topPriority {
                        self.topEntryIdAndPriority = (entry.id, updatedPriorityKey)
                    } else if updatedPriorityKey > topPriority && topId == id {
                        self.topEntryIdAndPriority = nil
                    }
                } else {
                    self.topEntryIdAndPriority = (entry.id, updatedPriorityKey)
                }
            } else {
                if self.topEntryIdAndPriority?.0 == id {
                    self.topEntryIdAndPriority = nil
                }
                self.entries.removeValue(forKey: id)
                removedEntries = true
            }
        }
        
        self.maybeFindAndActivateNewTopEntry()
        
        if removedEntries {
            var removedIds: [FetchManagerLocationEntryId] = []
            for (entryId, activeContext) in self.activeContexts {
                if self.entries[entryId] == nil {
                    removedIds.append(entryId)
                    activeContext.disposable?.dispose()
                }
            }
            for entryId in removedIds {
                self.activeContexts.removeValue(forKey: entryId)
            }
        }
        
        if let activeContext = self.activeContexts[id] {
            if activeContext.disposable == nil {
                if let entry = self.entries[id] {
                    let entryCompleted = self.entryCompleted
                    activeContext.disposable = self.postbox.mediaBox.fetchedResource(entry.resource, tag: entry.fetchTag, implNext: true).start(next: { value in
                        entryCompleted(id, value)
                    })
                } else {
                    assertionFailure()
                }
            }
        }
        
        if (previousPriorityKey != nil) != (updatedPriorityKey != nil) {
            if let statusContext = self.statusContexts[id] {
                if updatedPriorityKey != nil {
                    if !statusContext.hasEntry {
                        let previousStatus = statusContext.combinedStatus
                        statusContext.hasEntry = true
                        if let combinedStatus = statusContext.combinedStatus, combinedStatus != previousStatus {
                            for f in statusContext.subscribers.copyItems() {
                                f(combinedStatus)
                            }
                        }
                    } else {
                        assertionFailure()
                    }
                } else {
                    if statusContext.hasEntry {
                        let previousStatus = statusContext.combinedStatus
                        statusContext.hasEntry = false
                        if let combinedStatus = statusContext.combinedStatus, combinedStatus != previousStatus {
                            for f in statusContext.subscribers.copyItems() {
                                f(combinedStatus)
                            }
                        }
                    } else {
                        assertionFailure()
                    }
                }
            }
        }
    }
    
    func maybeFindAndActivateNewTopEntry() {
        if !self.entries.isEmpty {
            for (id, entry) in self.entries {
                if activeContexts[id] == nil {
                    let activeContext = FetchManagerActiveContext()
                    self.activeContexts[id] = activeContext
                    let entryCompleted = self.entryCompleted
                    activeContext.disposable = self.postbox.mediaBox.fetchedResource(entry.resource, tag: entry.fetchTag, implNext: true).start(next: { value in
                        entryCompleted(id, value)
                    })
                }
            }
        }
        
    }
    
    func cancelEntry(_ entryId: FetchManagerLocationEntryId) {
        var id: FetchManagerLocationEntryId = entryId
        if self.entries[id] == nil {
            for (key, _) in self.entries {
                if key.resourceId.isEqual(to: entryId.resourceId) {
                    id = key
                    break
                }
            }
        }
        
        if let _ = self.entries[id] {
            self.entries.removeValue(forKey: id)
            
            if let statusContext = self.statusContexts[id] {
                if statusContext.hasEntry {
                    let previousStatus = statusContext.combinedStatus
                    statusContext.hasEntry = false
                    if let combinedStatus = statusContext.combinedStatus, combinedStatus != previousStatus {
                        for f in statusContext.subscribers.copyItems() {
                            f(combinedStatus)
                        }
                    }
                } else {
                    assertionFailure()
                }
            }
        }
        
        if let activeContext = self.activeContexts[id] {
            activeContext.disposable?.dispose()
            activeContext.disposable = nil
            self.activeContexts.removeValue(forKey: id)
        }
        
        if self.topEntryIdAndPriority?.0 == id {
            self.topEntryIdAndPriority = nil
        }
        
        self.maybeFindAndActivateNewTopEntry()
    }
    
    func withFetchStatusContext(_ id: FetchManagerLocationEntryId, _ f: (FetchManagerStatusContext) -> Void) {
        let statusContext: FetchManagerStatusContext
        if let current = self.statusContexts[id] {
            statusContext = current
        } else {
            statusContext = FetchManagerStatusContext()
            self.statusContexts[id] = statusContext
            if self.entries[id] != nil {
                statusContext.hasEntry = true
            }
        }
        
        f(statusContext)
        
        if statusContext.isEmpty {
            statusContext.disposable?.dispose()
            self.statusContexts.removeValue(forKey: id)
        }
    }
    
    var isEmpty: Bool {
        return self.entries.isEmpty && self.activeContexts.isEmpty && self.statusContexts.isEmpty
    }
}

final class FetchManager {
    private let queue = Queue()
    private let postbox: Postbox
    private var nextEpisodeId: Int32 = 0
    private var nextUserInitiatedIndex: Int32 = 0
    
    private var categoryContexts: [FetchManagerCategory: FetchManagerCategoryContext] = [:]
    
    init(postbox: Postbox) {
        self.postbox = postbox
    }
    
    private func takeNextEpisodeId() -> Int32 {
        let value = self.nextEpisodeId
        self.nextEpisodeId += 1
        return value
    }
    
    private func takeNextUserInitiatedIndex() -> Int32 {
        let value = self.nextUserInitiatedIndex
        self.nextUserInitiatedIndex += 1
        return value
    }
    
    private func withCategoryContext(_ key: FetchManagerCategory, _ f: (FetchManagerCategoryContext) -> Void) {
        assert(self.queue.isCurrent())
        let context: FetchManagerCategoryContext
        if let current = self.categoryContexts[key] {
            context = current
        } else {
            let queue = self.queue
            context = FetchManagerCategoryContext(postbox: self.postbox, entryCompleted: { [weak self] id, source in
                queue.async {
                    if let strongSelf = self {
                        let postbox = strongSelf.postbox
                        switch source {
                        case .remote:
                            switch id.locationKey {
                            case let .messageId(messageId):
                                _ = (strongSelf.postbox.messageAtId(messageId) |> map { $0?.media.first as? TelegramMediaFile} |> filter {$0 != nil} |> map {$0!} |> mapToSignal { file -> Signal<Void, Void> in
                                    if !file.isMusic && !file.isAnimated && !file.isVideo && !file.isVoice && !file.isInstantVideo {
                                        return copyToDownloads(file, postbox: postbox)
                                    }
                                    return .single(Void())
                                }).start()
                            default:
                                break
                            }
                        default:
                            break
                        }
                        strongSelf.withCategoryContext(key, { context in
                            context.cancelEntry(id)
                        })
                    }
                }
            })
            self.categoryContexts[key] = context
        }
        
        f(context)
        
        if context.isEmpty {
            self.categoryContexts.removeValue(forKey: key)
        }
    }
    
    func interactivelyFetched(category: FetchManagerCategory, location: FetchManagerLocation, locationKey: FetchManagerLocationKey, resource: MediaResource, fetchTag: MediaResourceFetchTag?, elevatedPriority: Bool, userInitiated: Bool) -> Signal<Void, NoError> {
        let queue = self.queue
        return Signal { [weak self] subscriber in
            if let strongSelf = self {
                var assignedEpisode: Int32?
                var assignedUserInitiatedIndex: Int32?
                
                strongSelf.withCategoryContext(category, { context in
                    context.withEntry(id: FetchManagerLocationEntryId(location: location, resourceId: resource.id, locationKey: locationKey), takeNew: { return (resource, fetchTag, strongSelf.takeNextEpisodeId()) }, { entry in
                        assignedEpisode = entry.episode
                        entry.referenceCount += 1
                        if elevatedPriority {
                            entry.elevatedPriorityReferenceCount += 1
                        }
                        if userInitiated {
                            let userInitiatedIndex = strongSelf.takeNextUserInitiatedIndex()
                            assignedUserInitiatedIndex = userInitiatedIndex
                            entry.userInitiatedPriorityIndices.append(userInitiatedIndex)
                            entry.userInitiatedPriorityIndices.sort()
                        }
                    })
                })
                
                return ActionDisposable {
                    queue.async {
                        if let strongSelf = self {
                            strongSelf.withCategoryContext(category, { context in
                                context.withEntry(id: FetchManagerLocationEntryId(location: location, resourceId: resource.id, locationKey: locationKey), takeNew: nil, { entry in
                                    if entry.episode == assignedEpisode {
                                        entry.referenceCount -= 1
                                        assert(entry.referenceCount >= 0)
                                        if elevatedPriority {
                                            entry.elevatedPriorityReferenceCount -= 1
                                            assert(entry.elevatedPriorityReferenceCount >= 0)
                                        }
                                        if let userInitiatedIndex = assignedUserInitiatedIndex {
                                            if let index = entry.userInitiatedPriorityIndices.index(of: userInitiatedIndex) {
                                                entry.userInitiatedPriorityIndices.remove(at: index)
                                            } else {
                                                assertionFailure()
                                            }
                                        }
                                    }
                                })
                            })
                        }
                    }
                }
            } else {
                return EmptyDisposable
            }
            } |> runOn(self.queue)
    }
    
    func cancelInteractiveFetches(category: FetchManagerCategory, location: FetchManagerLocation, locationKey: FetchManagerLocationKey, resource: MediaResource) {
        self.queue.async {
            self.withCategoryContext(category, { context in
                context.cancelEntry(FetchManagerLocationEntryId(location: location, resourceId: resource.id, locationKey: locationKey))
            })
        }
    }
    
    func fetchStatus(category: FetchManagerCategory, location: FetchManagerLocation, locationKey: FetchManagerLocationKey, resource: MediaResource) -> Signal<MediaResourceStatus, NoError> {
        let queue = self.queue
        return Signal { [weak self] subscriber in
            if let strongSelf = self {
                var assignedIndex: Int?
                
                let entryId = FetchManagerLocationEntryId(location: location, resourceId: resource.id, locationKey: locationKey)
                strongSelf.withCategoryContext(category, { context in
                    context.withFetchStatusContext(entryId, { statusContext in
                        assignedIndex = statusContext.subscribers.add({ status in
                            subscriber.putNext(status)
                            if case .Local = status {
                                subscriber.putCompletion()
                            }
                        })
                        if let status = statusContext.combinedStatus {
                            subscriber.putNext(status)
                            if case .Local = status {
                                subscriber.putCompletion()
                            }
                        }
                        if statusContext.disposable == nil {
                            statusContext.disposable = strongSelf.postbox.mediaBox.resourceStatus(resource).start(next: { status in
                                queue.async {
                                    if let strongSelf = self {
                                        strongSelf.withCategoryContext(category, { context in
                                            context.withFetchStatusContext(entryId, { statusContext in
                                                statusContext.originalStatus = status
                                                
              
                                                
                                                if let combinedStatus = statusContext.combinedStatus {
                                                    for f in statusContext.subscribers.copyItems() {
                                                        f(combinedStatus)
                                                    }
                                                }
                                            })
                                        })
                                    }
                                }
                            })
                        }
                    })
                })
                
                return ActionDisposable {
                    queue.async {
                        if let strongSelf = self {
                            strongSelf.withCategoryContext(category, { context in
                                context.withFetchStatusContext(entryId, { statusContext in
                                    if let assignedIndex = assignedIndex {
                                        statusContext.subscribers.remove(assignedIndex)
                                    }
                                })
                            })
                        }
                    }
                }
            } else {
                return EmptyDisposable
            }
            } |> runOn(self.queue)
    }
}
