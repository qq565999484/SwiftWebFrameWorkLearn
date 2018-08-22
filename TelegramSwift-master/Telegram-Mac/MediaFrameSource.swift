import Foundation
import SwiftSignalKitMac
import CoreMedia

enum MediaTrackEvent {
    case frames([MediaTrackDecodableFrame])
    case endOfStream
}

final class MediaFrameSourceSeekResult {
    let buffers: MediaPlaybackBuffers
    let timestamp: CMTime
    
    init(buffers: MediaPlaybackBuffers, timestamp: CMTime) {
        self.buffers = buffers
        self.timestamp = timestamp
    }
}

enum MediaFrameSourceSeekError {
    case generic
}

protocol MediaFrameSource {
    func addEventSink(_ f: @escaping (MediaTrackEvent) -> Void) -> Int
    func removeEventSink(_ index: Int)
    func generateFrames(until timestamp: Double)
    func seek(timestamp: Double) -> Signal<QueueLocalObject<MediaFrameSourceSeekResult>, MediaFrameSourceSeekError>
}
