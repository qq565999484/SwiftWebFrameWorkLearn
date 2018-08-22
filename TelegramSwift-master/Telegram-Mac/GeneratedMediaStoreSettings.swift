//
//  GeneratedMediaStoreSettings.swift
//  Telegram
//
//  Created by keepcoder on 18/04/2017.
//  Copyright © 2017 Telegram. All rights reserved.
//

import Cocoa
import PostboxMac
import SwiftSignalKitMac

public struct GeneratedMediaStoreSettings: PreferencesEntry, Equatable {
    public let storeEditedPhotos: Bool
    
    public static var defaultSettings: GeneratedMediaStoreSettings {
        return GeneratedMediaStoreSettings(storeEditedPhotos: true)
    }
    
    init(storeEditedPhotos: Bool) {
        self.storeEditedPhotos = storeEditedPhotos
    }
    
    public init(decoder: PostboxDecoder) {
        self.storeEditedPhotos = decoder.decodeInt32ForKey("eph", orElse: 0) != 0
    }
    
    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt32(self.storeEditedPhotos ? 1 : 0, forKey: "eph")
    }
    
    public func isEqual(to: PreferencesEntry) -> Bool {
        if let to = to as? GeneratedMediaStoreSettings {
            return self == to
        } else {
            return false
        }
    }
    
    public static func ==(lhs: GeneratedMediaStoreSettings, rhs: GeneratedMediaStoreSettings) -> Bool {
        return lhs.storeEditedPhotos == rhs.storeEditedPhotos
    }
    
    func withUpdatedStoreEditedPhotos(_ storeEditedPhotos: Bool) -> GeneratedMediaStoreSettings {
        return GeneratedMediaStoreSettings(storeEditedPhotos: storeEditedPhotos)
    }
}

func updateGeneratedMediaStoreSettingsInteractively(postbox: Postbox, _ f: @escaping (GeneratedMediaStoreSettings) -> GeneratedMediaStoreSettings) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> Void in
        transaction.updatePreferencesEntry(key: ApplicationSpecificPreferencesKeys.generatedMediaStoreSettings, { entry in
            let currentSettings: GeneratedMediaStoreSettings
            if let entry = entry as? GeneratedMediaStoreSettings {
                currentSettings = entry
            } else {
                currentSettings = GeneratedMediaStoreSettings.defaultSettings
            }
            return f(currentSettings)
        })
    }
}
