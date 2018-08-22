//
//  PreparedChatHistoryViewTransition.swift
//  Telegram
//
//  Created by keepcoder on 19/04/2017.
//  Copyright © 2017 Telegram. All rights reserved.
//

import Cocoa
import SwiftSignalKitMac
import PostboxMac
import TelegramCoreMac

struct ChatHistoryViewTransition {
    let historyView: ChatHistoryView
    let deleteItems: [ListViewDeleteItem]
    let insertEntries: [ChatHistoryViewTransitionInsertEntry]
    let updateEntries: [ChatHistoryViewTransitionUpdateEntry]
    let options: ListViewDeleteAndInsertOptions
    let scrollToItem: ListViewScrollToItem?
    let stationaryItemRange: (Int, Int)?
    let initialData: InitialMessageHistoryData?
    let keyboardButtonsMessage: Message?
    let cachedData: CachedPeerData?
    let scrolledToIndex: MessageIndex?
}


enum ChatHistoryViewGridScrollPosition {
    case Unread(index: MessageIndex)
    case Index(index: MessageIndex, position: ListViewScrollPosition, directionHint: ListViewScrollToItemDirectionHint, animated: Bool)
}

func preparedChatHistoryViewTransition(from fromView: ChatHistoryView?, to toView: ChatHistoryView, reason: ChatHistoryViewTransitionReason, account: Account, peerId: PeerId, controllerInteraction: ChatInteraction, scrollPosition: ChatHistoryViewGridScrollPosition?, initialData: InitialMessageHistoryData?, keyboardButtonsMessage: Message?, cachedData: CachedPeerData?) -> Signal<ChatHistoryViewTransition, NoError> {
    return Signal { subscriber in
        let (deleteIndices, indicesAndItems, updateIndices) = mergeListsStableWithUpdates(leftList: fromView?.filteredEntries ?? [], rightList: toView.filteredEntries)
        
        var adjustedDeleteIndices: [ListViewDeleteItem] = []
        let previousCount: Int
        if let fromView = fromView {
            previousCount = fromView.filteredEntries.count
        } else {
            previousCount = 0;
        }
        for index in deleteIndices {
            adjustedDeleteIndices.append(ListViewDeleteItem(index: previousCount - 1 - index, directionHint: nil))
        }
        
        var adjustedIndicesAndItems: [ChatHistoryViewTransitionInsertEntry] = []
        var adjustedUpdateItems: [ChatHistoryViewTransitionUpdateEntry] = []
        let updatedCount = toView.filteredEntries.count
        
        var options: ListViewDeleteAndInsertOptions = []
        var maxAnimatedInsertionIndex = -1
        var stationaryItemRange: (Int, Int)?
        var scrollToItem: ListViewScrollToItem?
        
        switch reason {
        case let .Initial(fadeIn):
            if fadeIn {
                let _ = options.insert(.AnimateAlpha)
            } else {
                let _ = options.insert(.LowLatency)
                let _ = options.insert(.Synchronous)
            }
        case .InteractiveChanges:
            let _ = options.insert(.AnimateAlpha)
            let _ = options.insert(.AnimateInsertion)
            
            for (index, _, _) in indicesAndItems.sorted(by: { $0.0 > $1.0 }) {
                let adjustedIndex = updatedCount - 1 - index
                if adjustedIndex == maxAnimatedInsertionIndex + 1 {
                    maxAnimatedInsertionIndex += 1
                }
            }
        case .Reload:
            break
        case let .HoleChanges(filledHoleDirections, removeHoleDirections):
            if let (_, removeDirection) = removeHoleDirections.first {
                switch removeDirection {
                case .LowerToUpper:
                    var holeIndex: MessageIndex?
                    for (index, _) in filledHoleDirections {
                        if holeIndex == nil || index < holeIndex! {
                            holeIndex = index
                        }
                    }
                    
                    if let holeIndex = holeIndex {
                        for i in 0 ..< toView.filteredEntries.count {
                            if toView.filteredEntries[i].entry.index >= holeIndex {
                                let index = toView.filteredEntries.count - 1 - (i - 1)
                                stationaryItemRange = (index, Int.max)
                                break
                            }
                        }
                    }
                case .UpperToLower:
                    break
                case .AroundId:
                    break
                case .AroundIndex(_, let lowerComplete, let upperComplete, let clippingMinIndex, let clippingMaxIndex):
                    break
                }
            }
        }
        
        for (index, entry, previousIndex) in indicesAndItems {
            let adjustedIndex = updatedCount - 1 - index
            
            let adjustedPrevousIndex: Int?
            if let previousIndex = previousIndex {
                adjustedPrevousIndex = previousCount - 1 - previousIndex
            } else {
                adjustedPrevousIndex = nil
            }
            
            var directionHint: ListViewItemOperationDirectionHint?
            if maxAnimatedInsertionIndex >= 0 && adjustedIndex <= maxAnimatedInsertionIndex {
                directionHint = .Down
            }
            
            adjustedIndicesAndItems.append(ChatHistoryViewTransitionInsertEntry(index: adjustedIndex, previousIndex: adjustedPrevousIndex, entry: entry.entry, directionHint: directionHint))
        }
        
        for (index, entry, previousIndex) in updateIndices {
            let adjustedIndex = updatedCount - 1 - index
            let adjustedPreviousIndex = previousCount - 1 - previousIndex
            
            let directionHint: ListViewItemOperationDirectionHint? = nil
            adjustedUpdateItems.append(ChatHistoryViewTransitionUpdateEntry(index: adjustedIndex, previousIndex: adjustedPreviousIndex, entry: entry.entry, directionHint: directionHint))
        }
        
        var scrolledToIndex: MessageIndex?
        
        if let scrollPosition = scrollPosition {
            switch scrollPosition {
            case let .Unread(unreadIndex):
                var index = toView.filteredEntries.count - 1
                for entry in toView.filteredEntries {
                    if case .UnreadEntry = entry.entry {
                        scrollToItem = ListViewScrollToItem(index: index, position: .Bottom, animated: false, curve: .Default, directionHint: .Down)
                        break
                    }
                    index -= 1
                }
                
                if scrollToItem == nil {
                    var index = toView.filteredEntries.count - 1
                    for entry in toView.filteredEntries {
                        if entry.entry.index >= unreadIndex {
                            scrollToItem = ListViewScrollToItem(index: index, position: .Bottom, animated: false, curve: .Default,  directionHint: .Down)
                            break
                        }
                        index -= 1
                    }
                }
                
                if scrollToItem == nil {
                    var index = 0
                    for entry in toView.filteredEntries.reversed() {
                        if entry.entry.index < unreadIndex {
                            scrollToItem = ListViewScrollToItem(index: index, position: .Bottom, animated: false, curve: .Default, directionHint: .Down)
                            break
                        }
                        index += 1
                    }
                }
            case let .Index(scrollIndex, position, directionHint, animated):
                if case .Center = position {
                    scrolledToIndex = scrollIndex
                }
                var index = toView.filteredEntries.count - 1
                for entry in toView.filteredEntries {
                    if entry.entry.index >= scrollIndex {
                        scrollToItem = ListViewScrollToItem(index: index, position: position, animated: animated, curve: .Default, directionHint: directionHint)
                        break
                    }
                    index -= 1
                }
                
                if scrollToItem == nil {
                    var index = 0
                    for entry in toView.filteredEntries.reversed() {
                        if entry.entry.index < scrollIndex {
                            scrollToItem = ListViewScrollToItem(index: index, position: position, animated: animated, curve: .Default, directionHint: directionHint)
                            break
                        }
                        index += 1
                    }
                }
            }
        }
        
        subscriber.putNext(ChatHistoryViewTransition(historyView: toView, deleteItems: adjustedDeleteIndices, insertEntries: adjustedIndicesAndItems, updateEntries: adjustedUpdateItems, options: options, scrollToItem: scrollToItem, stationaryItemRange: stationaryItemRange, initialData: initialData, keyboardButtonsMessage: keyboardButtonsMessage, cachedData: cachedData, scrolledToIndex: scrolledToIndex))
        subscriber.putCompletion()
        
        return EmptyDisposable
    }
}
