//
//  PeerPresenceStatusManager.swift
//  Telegram-Mac
//
//  Created by keepcoder on 08/11/2016.
//  Copyright © 2016 Telegram. All rights reserved.
//

import Cocoa

import SwiftSignalKitMac
import TelegramCoreMac

final class PeerPresenceStatusManager {
    private let update: () -> Void
    private var timer: SwiftSignalKitMac.Timer?
    
    init(update: @escaping () -> Void) {
        self.update = update
    }
    
    deinit {
        self.timer?.invalidate()
    }
    
    func reset(presence: TelegramUserPresence) {
        timer?.invalidate()
        timer = nil
        
        let timestamp = CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970
        let timeout = userPresenceStringRefreshTimeout(presence, relativeTo: Int32(timestamp))
        if timeout.isFinite {
            self.timer = SwiftSignalKitMac.Timer(timeout: timeout, repeat: false, completion: { [weak self] in
                if let strongSelf = self {
                    strongSelf.update()
                }
                }, queue: Queue.mainQueue())
            self.timer?.start()
        }
    }
}
