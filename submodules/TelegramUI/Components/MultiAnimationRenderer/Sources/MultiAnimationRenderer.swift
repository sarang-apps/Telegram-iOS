import Foundation
import UIKit
import SwiftSignalKit
import Display
import AnimationCache
import Accelerate

public protocol MultiAnimationRenderer: AnyObject {
    func add(target: MultiAnimationRenderTarget, cache: AnimationCache, itemId: String, size: CGSize, fetch: @escaping (CGSize, AnimationCacheItemWriter) -> Disposable) -> Disposable
    func loadFirstFrameSynchronously(target: MultiAnimationRenderTarget, cache: AnimationCache, itemId: String, size: CGSize) -> Bool
    func loadFirstFrame(target: MultiAnimationRenderTarget, cache: AnimationCache, itemId: String, size: CGSize, completion: @escaping (Bool) -> Void) -> Disposable
}

private var nextRenderTargetId: Int64 = 1

open class MultiAnimationRenderTarget: SimpleLayer {
    public let id: Int64
    
    let deinitCallbacks = Bag<() -> Void>()
    let updateStateCallbacks = Bag<() -> Void>()
    
    public final var shouldBeAnimating: Bool = false {
        didSet {
            if self.shouldBeAnimating != oldValue {
                for f in self.updateStateCallbacks.copyItems() {
                    f()
                }
            }
        }
    }
    
    public override init() {
        assert(Thread.isMainThread)
        
        self.id = nextRenderTargetId
        nextRenderTargetId += 1
        
        super.init()
    }
    
    public override init(layer: Any) {
        guard let layer = layer as? MultiAnimationRenderTarget else {
            preconditionFailure()
        }
        
        self.id = layer.id
        
        super.init(layer: layer)
    }
    
    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        for f in self.deinitCallbacks.copyItems() {
            f()
        }
    }
    
    open func updateDisplayPlaceholder(displayPlaceholder: Bool) {
    }
    
    open func transitionToContents(_ contents: AnyObject) {
    }
}

private final class FrameGroup {
    let image: UIImage
    let badgeImage: UIImage?
    let size: CGSize
    let timestamp: Double
    
    init?(item: AnimationCacheItem, timestamp: Double) {
        guard let firstFrame = item.getFrame(at: timestamp, requestedFormat: .rgba) else {
            return nil
        }
        
        switch firstFrame.format {
        case let .rgba(data, width, height, bytesPerRow):
            let context = DrawingContext(size: CGSize(width: CGFloat(width), height: CGFloat(height)), scale: 1.0, opaque: false, bytesPerRow: bytesPerRow)
                
            data.withUnsafeBytes { bytes -> Void in
                memcpy(context.bytes, bytes.baseAddress!, height * bytesPerRow)
                
                /*var sourceBuffer = vImage_Buffer()
                sourceBuffer.width = UInt(width)
                sourceBuffer.height = UInt(height)
                sourceBuffer.data = UnsafeMutableRawPointer(mutating: bytes.baseAddress!.advanced(by: firstFrame.range.lowerBound))
                sourceBuffer.rowBytes = bytesPerRow
                
                var destinationBuffer = vImage_Buffer()
                destinationBuffer.width = UInt(32)
                destinationBuffer.height = UInt(32)
                destinationBuffer.data = context.bytes
                destinationBuffer.rowBytes = bytesPerRow
                
                vImageBoxConvolve_ARGB8888(&sourceBuffer,
                                           &destinationBuffer,
                                           nil,
                                           UInt(width - 32 - 16), UInt(height - 32 - 16),
                                           UInt32(31),
                                           UInt32(31),
                                           nil,
                                           vImage_Flags(kvImageEdgeExtend))*/
            }
            
            guard let image = context.generateImage() else {
                return nil
            }
            
            self.image = image
            self.size = CGSize(width: CGFloat(width), height: CGFloat(height))
            self.timestamp = timestamp
            self.badgeImage = nil
        default:
            return nil
        }
    }
}

private final class LoadFrameGroupTask {
    let task: () -> () -> Void
    
    init(task: @escaping () -> () -> Void) {
        self.task = task
    }
}

private final class ItemAnimationContext {
    static let queue = Queue(name: "ItemAnimationContext", qos: .default)
    
    private let cache: AnimationCache
    private let stateUpdated: () -> Void
    
    private var disposable: Disposable?
    private var displayLink: ConstantDisplayLinkAnimator?
    private var timestamp: Double = 0.0
    private var item: AnimationCacheItem?
    
    private var currentFrameGroup: FrameGroup?
    private var isLoadingFrameGroup: Bool = false
    
    private(set) var isPlaying: Bool = false {
        didSet {
            if self.isPlaying != oldValue {
                self.stateUpdated()
            }
        }
    }
    
    let targets = Bag<Weak<MultiAnimationRenderTarget>>()
    
    init(cache: AnimationCache, itemId: String, size: CGSize, fetch: @escaping (CGSize, AnimationCacheItemWriter) -> Disposable, stateUpdated: @escaping () -> Void) {
        self.cache = cache
        self.stateUpdated = stateUpdated
        
        self.disposable = cache.get(sourceId: itemId, size: size, fetch: fetch).start(next: { [weak self] result in
            Queue.mainQueue().async {
                guard let strongSelf = self else {
                    return
                }
                strongSelf.item = result.item
                strongSelf.updateIsPlaying()
                
                if result.item == nil {
                    for target in strongSelf.targets.copyItems() {
                        if let target = target.value {
                            target.updateDisplayPlaceholder(displayPlaceholder: true)
                        }
                    }
                }
            }
        })
    }
    
    deinit {
        self.disposable?.dispose()
        self.displayLink?.invalidate()
    }
    
    func updateAddedTarget(target: MultiAnimationRenderTarget) {
        if let currentFrameGroup = self.currentFrameGroup {
            if let cgImage = currentFrameGroup.image.cgImage {
                target.transitionToContents(cgImage)
            }
        }
        
        self.updateIsPlaying()
    }
    
    func updateIsPlaying() {
        var isPlaying = true
        if self.item == nil {
            isPlaying = false
        }
        
        var shouldBeAnimating = false
        for target in self.targets.copyItems() {
            if let target = target.value {
                if target.shouldBeAnimating {
                    shouldBeAnimating = true
                    break
                }
            }
        }
        if !shouldBeAnimating {
            isPlaying = false
        }
        
        self.isPlaying = isPlaying
    }
    
    func animationTick(advanceTimestamp: Double) -> LoadFrameGroupTask? {
        return self.update(advanceTimestamp: advanceTimestamp)
    }
    
    private func update(advanceTimestamp: Double?) -> LoadFrameGroupTask? {
        guard let item = self.item else {
            return nil
        }
        
        let timestamp = self.timestamp
        if let advanceTimestamp = advanceTimestamp {
            self.timestamp += advanceTimestamp
        }
        
        if let currentFrameGroup = self.currentFrameGroup, currentFrameGroup.timestamp == self.timestamp {
        } else if !self.isLoadingFrameGroup {
            self.isLoadingFrameGroup = true
            
            return LoadFrameGroupTask(task: { [weak self] in
                let currentFrameGroup = FrameGroup(item: item, timestamp: timestamp)
                
                return {
                    guard let strongSelf = self else {
                        return
                    }
                    
                    strongSelf.isLoadingFrameGroup = false
                    
                    if let currentFrameGroup = currentFrameGroup {
                        strongSelf.currentFrameGroup = currentFrameGroup
                        for target in strongSelf.targets.copyItems() {
                            if let target = target.value {
                                target.transitionToContents(currentFrameGroup.image.cgImage!)
                            }
                        }
                    }
                }
            })
        }
        
        if let _ = self.currentFrameGroup {
            for target in self.targets.copyItems() {
                if let target = target.value {
                    target.updateDisplayPlaceholder(displayPlaceholder: false)
                }
            }
        }
        
        return nil
    }
}

public final class MultiAnimationRendererImpl: MultiAnimationRenderer {
    private final class GroupContext {
        private let firstFrameQueue: Queue
        private let stateUpdated: () -> Void
        
        private var itemContexts: [String: ItemAnimationContext] = [:]
        
        private(set) var isPlaying: Bool = false {
            didSet {
                if self.isPlaying != oldValue {
                    self.stateUpdated()
                }
            }
        }
        
        init(firstFrameQueue: Queue, stateUpdated: @escaping () -> Void) {
            self.firstFrameQueue = firstFrameQueue
            self.stateUpdated = stateUpdated
        }
        
        func add(target: MultiAnimationRenderTarget, cache: AnimationCache, itemId: String, size: CGSize, fetch: @escaping (CGSize, AnimationCacheItemWriter) -> Disposable) -> Disposable {
            let itemContext: ItemAnimationContext
            if let current = self.itemContexts[itemId] {
                itemContext = current
            } else {
                itemContext = ItemAnimationContext(cache: cache, itemId: itemId, size: size, fetch: fetch, stateUpdated: { [weak self] in
                    guard let strongSelf = self else {
                        return
                    }
                    strongSelf.updateIsPlaying()
                })
                self.itemContexts[itemId] = itemContext
            }
            
            let index = itemContext.targets.add(Weak(target))
            itemContext.updateAddedTarget(target: target)
            
            let deinitIndex = target.deinitCallbacks.add { [weak self, weak itemContext] in
                Queue.mainQueue().async {
                    guard let strongSelf = self, let itemContext = itemContext, strongSelf.itemContexts[itemId] === itemContext else {
                        return
                    }
                    itemContext.targets.remove(index)
                    if itemContext.targets.isEmpty {
                        strongSelf.itemContexts.removeValue(forKey: itemId)
                    }
                }
            }
            
            let updateStateIndex = target.updateStateCallbacks.add { [weak itemContext] in
                guard let itemContext = itemContext else {
                    return
                }
                itemContext.updateIsPlaying()
            }
            
            return ActionDisposable { [weak self, weak itemContext, weak target] in
                guard let strongSelf = self, let itemContext = itemContext, strongSelf.itemContexts[itemId] === itemContext else {
                    return
                }
                if let target = target {
                    target.deinitCallbacks.remove(deinitIndex)
                    target.updateStateCallbacks.remove(updateStateIndex)
                }
                itemContext.targets.remove(index)
                if itemContext.targets.isEmpty {
                    strongSelf.itemContexts.removeValue(forKey: itemId)
                }
            }
        }
        
        func loadFirstFrameSynchronously(target: MultiAnimationRenderTarget, cache: AnimationCache, itemId: String, size: CGSize) -> Bool {
            if let item = cache.getFirstFrameSynchronously(sourceId: itemId, size: size) {
                guard let frameGroup = FrameGroup(item: item, timestamp: 0.0) else {
                    return false
                }
                
                target.contents = frameGroup.image.cgImage
                
                return true
            } else {
                return false
            }
        }
        
        func loadFirstFrame(target: MultiAnimationRenderTarget, cache: AnimationCache, itemId: String, size: CGSize, completion: @escaping (Bool) -> Void) -> Disposable {
            return cache.getFirstFrame(queue: self.firstFrameQueue, sourceId: itemId, size: size, completion: { [weak target] item in
                guard let item = item else {
                    Queue.mainQueue().async {
                        completion(false)
                    }
                    return
                }
                
                let frameGroup = FrameGroup(item: item, timestamp: 0.0)
                
                Queue.mainQueue().async {
                    guard let target = target else {
                        completion(false)
                        return
                    }
                    if let frameGroup = frameGroup {
                        target.contents = frameGroup.image.cgImage
                        
                        completion(true)
                    } else {
                        completion(false)
                    }
                }
            })
        }
        
        private func updateIsPlaying() {
            var isPlaying = false
            for (_, itemContext) in self.itemContexts {
                if itemContext.isPlaying {
                    isPlaying = true
                    break
                }
            }
            
            self.isPlaying = isPlaying
        }
        
        func animationTick(advanceTimestamp: Double) -> [LoadFrameGroupTask] {
            var tasks: [LoadFrameGroupTask] = []
            for (_, itemContext) in self.itemContexts {
                if itemContext.isPlaying {
                    if let task = itemContext.animationTick(advanceTimestamp: advanceTimestamp) {
                        tasks.append(task)
                    }
                }
            }
            
            return tasks
        }
    }
    
    public static let firstFrameQueue = Queue(name: "MultiAnimationRenderer-FirstFrame", qos: .userInteractive)
    
    private var groupContext: GroupContext?
    private var frameSkip: Int
    private var displayLink: ConstantDisplayLinkAnimator?
    
    private(set) var isPlaying: Bool = false {
        didSet {
            if self.isPlaying != oldValue {
                if self.isPlaying {
                    if self.displayLink == nil {
                        self.displayLink = ConstantDisplayLinkAnimator { [weak self] in
                            guard let strongSelf = self else {
                                return
                            }
                            strongSelf.animationTick()
                        }
                        self.displayLink?.frameInterval = self.frameSkip
                        self.displayLink?.isPaused = false
                    }
                } else {
                    if let displayLink = self.displayLink {
                        self.displayLink = nil
                        displayLink.invalidate()
                    }
                }
            }
        }
    }
    
    public init() {
        if !ProcessInfo.processInfo.isLowPowerModeEnabled && ProcessInfo.processInfo.activeProcessorCount > 2 {
            self.frameSkip = 1
        } else {
            self.frameSkip = 2
        }
    }
    
    public func add(target: MultiAnimationRenderTarget, cache: AnimationCache, itemId: String, size: CGSize, fetch: @escaping (CGSize, AnimationCacheItemWriter) -> Disposable) -> Disposable {
        let groupContext: GroupContext
        if let current = self.groupContext {
            groupContext = current
        } else {
            groupContext = GroupContext(firstFrameQueue: MultiAnimationRendererImpl.firstFrameQueue, stateUpdated: { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.updateIsPlaying()
            })
            self.groupContext = groupContext
        }
        
        let disposable = groupContext.add(target: target, cache: cache, itemId: itemId, size: size, fetch: fetch)
        
        return ActionDisposable {
            disposable.dispose()
        }
    }
    
    public func loadFirstFrameSynchronously(target: MultiAnimationRenderTarget, cache: AnimationCache, itemId: String, size: CGSize) -> Bool {
        let groupContext: GroupContext
        if let current = self.groupContext {
            groupContext = current
        } else {
            groupContext = GroupContext(firstFrameQueue: MultiAnimationRendererImpl.firstFrameQueue, stateUpdated: { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.updateIsPlaying()
            })
            self.groupContext = groupContext
        }
        
        return groupContext.loadFirstFrameSynchronously(target: target, cache: cache, itemId: itemId, size: size)
    }
    
    public func loadFirstFrame(target: MultiAnimationRenderTarget, cache: AnimationCache, itemId: String, size: CGSize, completion: @escaping (Bool) -> Void) -> Disposable {
        let groupContext: GroupContext
        if let current = self.groupContext {
            groupContext = current
        } else {
            groupContext = GroupContext(firstFrameQueue: MultiAnimationRendererImpl.firstFrameQueue, stateUpdated: { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.updateIsPlaying()
            })
            self.groupContext = groupContext
        }
        
        return groupContext.loadFirstFrame(target: target, cache: cache, itemId: itemId, size: size, completion: completion)
    }
    
    private func updateIsPlaying() {
        var isPlaying = false
        if let groupContext = self.groupContext {
            if groupContext.isPlaying {
                isPlaying = true
            }
        }
        
        self.isPlaying = isPlaying
    }
    
    private func animationTick() {
        let secondsPerFrame = Double(self.frameSkip) / 60.0
        
        var tasks: [LoadFrameGroupTask] = []
        if let groupContext = self.groupContext {
            if groupContext.isPlaying {
                tasks.append(contentsOf: groupContext.animationTick(advanceTimestamp: secondsPerFrame))
            }
        }
        
        if !tasks.isEmpty {
            ItemAnimationContext.queue.async {
                var completions: [() -> Void] = []
                for task in tasks {
                    let complete = task.task()
                    completions.append(complete)
                }
                
                if !completions.isEmpty {
                    Queue.mainQueue().async {
                        for completion in completions {
                            completion()
                        }
                    }
                }
            }
        }
    }
}
