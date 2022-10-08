import Foundation
import UIKit
import SwiftSignalKit
import Display
import AnimationCache
import MultiAnimationRenderer
import ComponentFlow
import AccountContext
import TelegramCore
import Postbox
import EmojiTextAttachmentView
import AppBundle
import TextFormat
import Lottie
import GZip
import HierarchyTrackingLayer

public final class EmojiStatusComponent: Component {
    public typealias EnvironmentType = Empty
    
    public enum AnimationContent: Equatable {
        case file(file: TelegramMediaFile)
        case customEmoji(fileId: Int64)
        
        var fileId: MediaId {
            switch self {
            case let .file(file):
                return file.fileId
            case let .customEmoji(fileId):
                return MediaId(namespace: Namespaces.Media.CloudFile, id: fileId)
            }
        }
    }
    
    public enum LoopMode: Equatable {
        case forever
        case count(Int)
    }
    
    public enum SizeType {
        case compact
        case large
    }
    
    public enum Content: Equatable {
        case none
        case premium(color: UIColor)
        case verified(fillColor: UIColor, foregroundColor: UIColor, sizeType: SizeType)
        case text(color: UIColor, string: String)
        case animation(content: AnimationContent, size: CGSize, placeholderColor: UIColor, themeColor: UIColor?, loopMode: LoopMode)
        case topic(title: String, colorIndex: Int, size: CGSize)
    }
    
    public let context: AccountContext
    public let animationCache: AnimationCache
    public let animationRenderer: MultiAnimationRenderer
    public let content: Content
    public let isVisibleForAnimations: Bool
    public let useSharedAnimation: Bool
    public let action: (() -> Void)?
    public let emojiFileUpdated: ((TelegramMediaFile?) -> Void)?
    
    public init(
        context: AccountContext,
        animationCache: AnimationCache,
        animationRenderer: MultiAnimationRenderer,
        content: Content,
        isVisibleForAnimations: Bool,
        useSharedAnimation: Bool = false,
        action: (() -> Void)?,
        emojiFileUpdated: ((TelegramMediaFile?) -> Void)? = nil
    ) {
        self.context = context
        self.animationCache = animationCache
        self.animationRenderer = animationRenderer
        self.content = content
        self.isVisibleForAnimations = isVisibleForAnimations
        self.useSharedAnimation = useSharedAnimation
        self.action = action
        self.emojiFileUpdated = emojiFileUpdated
    }
    
    public func withVisibleForAnimations(_ isVisibleForAnimations: Bool) -> EmojiStatusComponent {
        return EmojiStatusComponent(
            context: self.context,
            animationCache: self.animationCache,
            animationRenderer: self.animationRenderer,
            content: self.content,
            isVisibleForAnimations: isVisibleForAnimations,
            useSharedAnimation: self.useSharedAnimation,
            action: self.action,
            emojiFileUpdated: self.emojiFileUpdated
        )
    }
    
    public static func ==(lhs: EmojiStatusComponent, rhs: EmojiStatusComponent) -> Bool {
        if lhs.context !== rhs.context {
            return false
        }
        if lhs.animationCache !== rhs.animationCache {
            return false
        }
        if lhs.animationRenderer !== rhs.animationRenderer {
            return false
        }
        if lhs.content != rhs.content {
            return false
        }
        if lhs.isVisibleForAnimations != rhs.isVisibleForAnimations {
            return false
        }
        if lhs.useSharedAnimation != rhs.useSharedAnimation {
            return false
        }
        return true
    }

    public final class View: UIView {
        private final class AnimationFileProperties {
            let path: String
            let coloredComposition: Animation?
            
            init(path: String, coloredComposition: Animation?) {
                self.path = path
                self.coloredComposition = coloredComposition
            }
            
            static func load(from path: String) -> AnimationFileProperties {
                guard let size = fileSize(path), size < 1024 * 1024 else {
                    return AnimationFileProperties(path: path, coloredComposition: nil)
                }
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                    return AnimationFileProperties(path: path, coloredComposition: nil)
                }
                guard let unzippedData = TGGUnzipData(data, 1024 * 1024) else {
                    return AnimationFileProperties(path: path, coloredComposition: nil)
                }
                
                var coloredComposition: Animation?
                if let composition = try? Animation.from(data: unzippedData) {
                    coloredComposition = composition
                }
                
                return AnimationFileProperties(path: path, coloredComposition: coloredComposition)
            }
        }
        
        private weak var state: EmptyComponentState?
        private var component: EmojiStatusComponent?
        private var iconView: UIImageView?
        private var animationLayer: InlineStickerItemLayer?
        private var lottieAnimationView: AnimationView?
        private let hierarchyTrackingLayer: HierarchyTrackingLayer
        
        private var emojiFile: TelegramMediaFile?
        private var emojiFileDataProperties: AnimationFileProperties?
        private var emojiFileDisposable: Disposable?
        private var emojiFileDataPathDisposable: Disposable?
        
        override init(frame: CGRect) {
            self.hierarchyTrackingLayer = HierarchyTrackingLayer()
            
            super.init(frame: frame)
            
            self.layer.addSublayer(self.hierarchyTrackingLayer)
            
            self.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.tapGesture(_:))))
            
            self.hierarchyTrackingLayer.didEnterHierarchy = { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                if let lottieAnimationView = strongSelf.lottieAnimationView {
                    lottieAnimationView.play()
                }
            }
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        deinit {
            self.emojiFileDisposable?.dispose()
            self.emojiFileDataPathDisposable?.dispose()
        }
        
        @objc private func tapGesture(_ recognizer: UITapGestureRecognizer) {
            if case .ended = recognizer.state {
                self.component?.action?()
            }
        }
        
        func update(component: EmojiStatusComponent, availableSize: CGSize, state: EmptyComponentState, environment: Environment<EnvironmentType>, transition: Transition) -> CGSize {
            self.state = state
            
            var iconImage: UIImage?
            var emojiFileId: Int64?
            var emojiPlaceholderColor: UIColor?
            var emojiThemeColor: UIColor?
            var emojiLoopMode: LoopMode?
            var emojiSize = CGSize()
            
            self.isUserInteractionEnabled = component.action != nil
            
            //let previousContent = self.component?.content
            if self.component?.content != component.content {
                switch component.content {
                case .none:
                    iconImage = nil
                case let .premium(color):
                    if let sourceImage = UIImage(bundleImageName: "Chat/Input/Media/EntityInputPremiumIcon") {
                        iconImage = generateImage(sourceImage.size, contextGenerator: { size, context in
                            if let cgImage = sourceImage.cgImage {
                                context.clear(CGRect(origin: CGPoint(), size: size))
                                let imageSize = CGSize(width: sourceImage.size.width - 8.0, height: sourceImage.size.height - 8.0)
                                context.clip(to: CGRect(origin: CGPoint(x: floor((size.width - imageSize.width) / 2.0), y: floor((size.height - imageSize.height) / 2.0)), size: imageSize), mask: cgImage)
                                
                                context.setFillColor(color.cgColor)
                                context.fill(CGRect(origin: CGPoint(), size: size))
                            }
                        }, opaque: false)
                    } else {
                        iconImage = nil
                    }
                case let .topic(title, colorIndex, size):
                    func generateTopicIcon(backgroundColors: [UIColor], strokeColors: [UIColor]) -> UIImage? {
                        return generateImage(size, rotatedContext: { size, context in
                            context.clear(CGRect(origin: .zero, size: size))

                            context.saveGState()
                            
                            let scale: CGFloat = size.width / 32.0
                            context.translateBy(x: size.width / 2.0, y: size.height / 2.0)
                            context.scaleBy(x: scale, y: scale)
                            context.translateBy(x: -14.0 - UIScreenPixel, y: -14.0 - UIScreenPixel)
                            
                            let _ = try? drawSvgPath(context, path: "M24.1835,4.71703 C21.7304,2.42169 18.2984,0.995605 14.5,0.995605 C7.04416,0.995605 1.0,6.49029 1.0,13.2683 C1.0,17.1341 2.80572,20.3028 5.87839,22.5523 C6.27132,22.84 6.63324,24.4385 5.75738,25.7811 C5.39922,26.3301 5.00492,26.7573 4.70138,27.0861 C4.26262,27.5614 4.01347,27.8313 4.33716,27.967 C4.67478,28.1086 6.66968,28.1787 8.10952,27.3712 C9.23649,26.7392 9.91903,26.1087 10.3787,25.6842 C10.7588,25.3331 10.9864,25.1228 11.187,25.1688 C11.9059,25.3337 12.6478,25.4461 13.4075,25.5015 C13.4178,25.5022 13.4282,25.503 13.4386,25.5037 C13.7888,25.5284 14.1428,25.5411 14.5,25.5411 C21.9558,25.5411 28.0,20.0464 28.0,13.2683 C28.0,9.94336 26.5455,6.92722 24.1835,4.71703 ")
                            context.closePath()
                            context.clip()
                            
                            let colorsArray = backgroundColors.map { $0.cgColor } as NSArray
                            var locations: [CGFloat] = [0.0, 1.0]
                            let gradient = CGGradient(colorsSpace: deviceColorSpace, colors: colorsArray, locations: &locations)!
                            context.drawLinearGradient(gradient, start: CGPoint(), end: CGPoint(x: 0.0, y: size.height), options: CGGradientDrawingOptions())
                            
                            context.resetClip()
                            
                            let _ = try? drawSvgPath(context, path: "M24.1835,4.71703 C21.7304,2.42169 18.2984,0.995605 14.5,0.995605 C7.04416,0.995605 1.0,6.49029 1.0,13.2683 C1.0,17.1341 2.80572,20.3028 5.87839,22.5523 C6.27132,22.84 6.63324,24.4385 5.75738,25.7811 C5.39922,26.3301 5.00492,26.7573 4.70138,27.0861 C4.26262,27.5614 4.01347,27.8313 4.33716,27.967 C4.67478,28.1086 6.66968,28.1787 8.10952,27.3712 C9.23649,26.7392 9.91903,26.1087 10.3787,25.6842 C10.7588,25.3331 10.9864,25.1228 11.187,25.1688 C11.9059,25.3337 12.6478,25.4461 13.4075,25.5015 C13.4178,25.5022 13.4282,25.503 13.4386,25.5037 C13.7888,25.5284 14.1428,25.5411 14.5,25.5411 C21.9558,25.5411 28.0,20.0464 28.0,13.2683 C28.0,9.94336 26.5455,6.92722 24.1835,4.71703 ")
                            context.closePath()
                            if let path = context.path {
                                let strokePath = path.copy(strokingWithWidth: 1.0 + UIScreenPixel, lineCap: .round, lineJoin: .round, miterLimit: 0.0)
                                context.beginPath()
                                context.addPath(strokePath)
                                context.clip()
                                
                                let colorsArray = strokeColors.map { $0.cgColor } as NSArray
                                var locations: [CGFloat] = [0.0, 1.0]
                                let gradient = CGGradient(colorsSpace: deviceColorSpace, colors: colorsArray, locations: &locations)!
                                context.drawLinearGradient(gradient, start: CGPoint(), end: CGPoint(x: 0.0, y: size.height), options: CGGradientDrawingOptions())
                            }
                            
                            context.restoreGState()
                            
                            let fontSize = round(15.0 * scale)
                            
                            let attributedString = NSAttributedString(string: title, attributes: [NSAttributedString.Key.font: Font.with(size: fontSize, design: .round, weight: .bold), NSAttributedString.Key.foregroundColor: UIColor.white])
                            
                            let line = CTLineCreateWithAttributedString(attributedString)
                            let lineBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
                            
                            
                            let lineOffset = CGPoint(x: title == "B" ? 1.0 : 0.0, y: floorToScreenPixels(0.67 * scale))
                            let lineOrigin = CGPoint(x: floorToScreenPixels(-lineBounds.origin.x + (size.width - lineBounds.size.width) / 2.0) + lineOffset.x, y: floorToScreenPixels(-lineBounds.origin.y + (size.height - lineBounds.size.height) / 2.0) + lineOffset.y)
                            
                            context.translateBy(x: size.width / 2.0, y: size.height / 2.0)
                            context.scaleBy(x: 1.0, y: -1.0)
                            context.translateBy(x: -size.width / 2.0, y: -size.height / 2.0)
                            
                            context.translateBy(x: lineOrigin.x, y: lineOrigin.y)
                            CTLineDraw(line, context)
                            context.translateBy(x: -lineOrigin.x, y: -lineOrigin.y)
                        })
                    }
                    
                    let topicColors: [([UInt32], [UInt32])] = [
                        ([0x6FB9F0, 0x0261E4], [0x026CB5, 0x064BB7]),
                        ([0x6FB9F0, 0x0261E4], [0x026CB5, 0x064BB7]),
                        ([0xFFD67E, 0xFC8601], [0xDA9400, 0xFA5F00]),
                        ([0xCB86DB, 0x9338AF], [0x812E98, 0x6F2B87]),
                        ([0x8EEE98, 0x02B504], [0x02A01B, 0x009716]),
                        ([0xFF93B2, 0xE23264], [0xFC447A, 0xC80C46]),
                        ([0xFB6F5F, 0xD72615], [0xDC1908, 0xB61506])
                    ]
                    let clippedIndex = colorIndex % topicColors.count
                    
                    if let image = generateTopicIcon(backgroundColors: topicColors[clippedIndex].0.map(UIColor.init(rgb:)), strokeColors: topicColors[clippedIndex].1.map(UIColor.init(rgb:))) {
                        iconImage = image
                    } else {
                        iconImage = nil
                    }
                case let .verified(fillColor, foregroundColor, sizeType):
                    let imageNamePrefix: String
                    switch sizeType {
                    case .compact:
                        imageNamePrefix = "Chat List/PeerVerifiedIcon"
                    case .large:
                        imageNamePrefix = "Peer Info/VerifiedIcon"
                    }
                    
                    if let backgroundImage = UIImage(bundleImageName: "\(imageNamePrefix)Background"), let foregroundImage = UIImage(bundleImageName: "\(imageNamePrefix)Foreground") {
                        iconImage = generateImage(backgroundImage.size, contextGenerator: { size, context in
                            if let backgroundCgImage = backgroundImage.cgImage, let foregroundCgImage = foregroundImage.cgImage {
                                context.clear(CGRect(origin: CGPoint(), size: size))
                                context.saveGState()
                                context.clip(to: CGRect(origin: .zero, size: size), mask: backgroundCgImage)

                                context.setFillColor(fillColor.cgColor)
                                context.fill(CGRect(origin: CGPoint(), size: size))
                                context.restoreGState()
                                
                                context.setBlendMode(.copy)
                                context.clip(to: CGRect(origin: .zero, size: size), mask: foregroundCgImage)
                                context.setFillColor(foregroundColor.cgColor)
                                context.fill(CGRect(origin: CGPoint(), size: size))
                            }
                        }, opaque: false)
                    } else {
                        iconImage = nil
                    }
                case let .text(color, string):
                    let titleString = NSAttributedString(string: string, font: Font.bold(10.0), textColor: color, paragraphAlignment: .center)
                    let stringRect = titleString.boundingRect(with: CGSize(width: 100.0, height: 16.0), options: .usesLineFragmentOrigin, context: nil)
                    
                    iconImage = generateImage(CGSize(width: floor(stringRect.width) + 11.0, height: 16.0), contextGenerator: { size, context in
                        let bounds = CGRect(origin: CGPoint(), size: size)
                        context.clear(bounds)
                        
                        context.setFillColor(color.cgColor)
                        context.setStrokeColor(color.cgColor)
                        context.setLineWidth(1.0)
                        
                        context.addPath(UIBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 2.0).cgPath)
                        context.strokePath()
                        
                        let titlePath = CGMutablePath()
                        titlePath.addRect(bounds.offsetBy(dx: 0.0, dy: -2.0 + UIScreenPixel))
                        let titleFramesetter = CTFramesetterCreateWithAttributedString(titleString as CFAttributedString)
                        let titleFrame = CTFramesetterCreateFrame(titleFramesetter, CFRangeMake(0, titleString.length), titlePath, nil)
                        CTFrameDraw(titleFrame, context)
                    })
                case let .animation(animationContent, size, placeholderColor, themeColor, loopMode):
                    iconImage = nil
                    emojiFileId = animationContent.fileId.id
                    emojiPlaceholderColor = placeholderColor
                    emojiThemeColor = themeColor
                    emojiSize = size
                    emojiLoopMode = loopMode
                    
                    if case let .animation(previousAnimationContent, _, _, _, _) = self.component?.content {
                        if previousAnimationContent.fileId != animationContent.fileId {
                            self.emojiFileDisposable?.dispose()
                            self.emojiFileDisposable = nil
                            self.emojiFileDataPathDisposable?.dispose()
                            self.emojiFileDataPathDisposable = nil
                            
                            self.emojiFile = nil
                            self.emojiFileDataProperties = nil
                            
                            if let animationLayer = self.animationLayer {
                                self.animationLayer = nil
                                
                                if !transition.animation.isImmediate {
                                    animationLayer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false, completion: { [weak animationLayer] _ in
                                        animationLayer?.removeFromSuperlayer()
                                    })
                                    animationLayer.animateScale(from: 1.0, to: 0.01, duration: 0.2, removeOnCompletion: false)
                                } else {
                                    animationLayer.removeFromSuperlayer()
                                }
                            }
                            if let lottieAnimationView = self.lottieAnimationView {
                                self.lottieAnimationView = nil
                                
                                if !transition.animation.isImmediate {
                                    lottieAnimationView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false, completion: { [weak lottieAnimationView] _ in
                                        lottieAnimationView?.removeFromSuperview()
                                    })
                                    lottieAnimationView.layer.animateScale(from: 1.0, to: 0.01, duration: 0.2, removeOnCompletion: false)
                                } else {
                                    lottieAnimationView.removeFromSuperview()
                                }
                            }
                        }
                    }
                    
                    switch animationContent {
                    case let .file(file):
                        self.emojiFile = file
                    case .customEmoji:
                        break
                    }
                }
            } else {
                iconImage = self.iconView?.image
                if case let .animation(animationContent, size, placeholderColor, themeColor, loopMode) = component.content {
                    emojiFileId = animationContent.fileId.id
                    emojiPlaceholderColor = placeholderColor
                    emojiThemeColor = themeColor
                    emojiLoopMode = loopMode
                    emojiSize = size
                }
            }
            
            self.component = component
            
            var size = CGSize()
            
            if let iconImage = iconImage {
                let iconView: UIImageView
                if let current = self.iconView {
                    iconView = current
                } else {
                    iconView = UIImageView()
                    self.iconView = iconView
                    self.addSubview(iconView)
                    
                    if !transition.animation.isImmediate {
                        iconView.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
                        iconView.layer.animateSpring(from: 0.1 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.5)
                    }
                }
                iconView.image = iconImage
                
                var useFit = false
                switch component.content {
                case .text:
                    useFit = true
                case .verified(_, _, sizeType: .compact):
                    useFit = true
                default:
                    break
                }
                if useFit {
                    size = CGSize(width: iconImage.size.width, height: availableSize.height)
                    iconView.frame = CGRect(origin: CGPoint(x: floor((size.width - iconImage.size.width) / 2.0), y: floor((size.height - iconImage.size.height) / 2.0)), size: iconImage.size)
                } else {
                    size = iconImage.size.aspectFilled(availableSize)
                    iconView.frame = CGRect(origin: CGPoint(), size: size)
                }
            } else {
                if let iconView = self.iconView {
                    self.iconView = nil
                    
                    if !transition.animation.isImmediate {
                        iconView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false, completion: { [weak iconView] _ in
                            iconView?.removeFromSuperview()
                        })
                        iconView.layer.animateScale(from: 1.0, to: 0.01, duration: 0.2, removeOnCompletion: false)
                    } else {
                        iconView.removeFromSuperview()
                    }
                }
            }
            
            let emojiFileUpdated = component.emojiFileUpdated
            if let emojiFileId = emojiFileId, let emojiPlaceholderColor = emojiPlaceholderColor, let emojiLoopMode = emojiLoopMode {
                size = availableSize
                
                if let emojiFile = self.emojiFile {
                    self.emojiFileDisposable?.dispose()
                    self.emojiFileDisposable = nil
                    self.emojiFileDataPathDisposable?.dispose()
                    self.emojiFileDataPathDisposable = nil
                    
                    let animationLayer: InlineStickerItemLayer
                    if let current = self.animationLayer {
                        animationLayer = current
                    } else {
                        let loopCount: Int?
                        switch emojiLoopMode {
                        case .forever:
                            loopCount = nil
                        case let .count(value):
                            loopCount = value
                        }
                        animationLayer = InlineStickerItemLayer(
                            context: component.context,
                            attemptSynchronousLoad: false,
                            emoji: ChatTextInputTextCustomEmojiAttribute(interactivelySelectedFromPackId: nil, fileId: emojiFile.fileId.id, file: emojiFile),
                            file: emojiFile,
                            cache: component.animationCache,
                            renderer: component.animationRenderer,
                            unique: !component.useSharedAnimation,
                            placeholderColor: emojiPlaceholderColor,
                            pointSize: emojiSize,
                            loopCount: loopCount
                        )
                        self.animationLayer = animationLayer
                        self.layer.addSublayer(animationLayer)
                        
                        if !transition.animation.isImmediate {
                            animationLayer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
                            animationLayer.animateSpring(from: 0.1 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.5)
                        }
                    }
                    
                    var accentTint = false
                    if let _ = emojiThemeColor {
                        for attribute in emojiFile.attributes {
                            if case let .CustomEmoji(_, _, packReference) = attribute {
                                switch packReference {
                                case let .id(id, _):
                                    if id == 773947703670341676 || id == 2964141614563343 {
                                        accentTint = true
                                    }
                                default:
                                    break
                                }
                            }
                        }
                    }
                    if accentTint {
                        animationLayer.contentTintColor = emojiThemeColor
                    } else {
                        animationLayer.contentTintColor = nil
                    }
                    
                    animationLayer.frame = CGRect(origin: CGPoint(), size: size)
                    animationLayer.isVisibleForAnimations = component.isVisibleForAnimations
                    /*} else {
                        if self.emojiFileDataPathDisposable == nil {
                            let account = component.context.account
                            self.emojiFileDataPathDisposable = (Signal<AnimationFileProperties?, NoError> { subscriber in
                                let disposable = MetaDisposable()
                                
                                let _ = (account.postbox.mediaBox.resourceData(emojiFile.resource)
                                |> take(1)).start(next: { firstAttemptData in
                                    if firstAttemptData.complete {
                                        subscriber.putNext(AnimationFileProperties.load(from: firstAttemptData.path))
                                        subscriber.putCompletion()
                                    } else {
                                        let fetchDisposable = freeMediaFileInteractiveFetched(account: account, fileReference: .standalone(media: emojiFile)).start()
                                        let dataDisposable = account.postbox.mediaBox.resourceData(emojiFile.resource).start(next: { data in
                                            if data.complete {
                                                subscriber.putNext(AnimationFileProperties.load(from: data.path))
                                                subscriber.putCompletion()
                                            }
                                        })
                                        
                                        disposable.set(ActionDisposable {
                                            fetchDisposable.dispose()
                                            dataDisposable.dispose()
                                        })
                                    }
                                })
                                
                                return disposable
                            }
                            |> deliverOnMainQueue).start(next: { [weak self] properties in
                                guard let strongSelf = self else {
                                    return
                                }
                                strongSelf.emojiFileDataProperties = properties
                                strongSelf.state?.updated(transition: transition)
                            })
                        }
                    }*/
                } else {
                    if self.emojiFileDisposable == nil {
                        self.emojiFileDisposable = (component.context.engine.stickers.resolveInlineStickers(fileIds: [emojiFileId])
                        |> deliverOnMainQueue).start(next: { [weak self] result in
                            guard let strongSelf = self else {
                                return
                            }
                            strongSelf.emojiFile = result[emojiFileId]
                            strongSelf.emojiFileDataProperties = nil
                            strongSelf.state?.updated(transition: transition)
                            
                            emojiFileUpdated?(result[emojiFileId])
                        })
                    }
                }
            } else {
                if let _ = self.emojiFile {
                    self.emojiFile = nil
                    self.emojiFileDataProperties = nil
                    emojiFileUpdated?(nil)
                }
                
                self.emojiFileDisposable?.dispose()
                self.emojiFileDisposable = nil
                self.emojiFileDataPathDisposable?.dispose()
                self.emojiFileDataPathDisposable = nil
                
                if let animationLayer = self.animationLayer {
                    self.animationLayer = nil
                    
                    if !transition.animation.isImmediate {
                        animationLayer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false, completion: { [weak animationLayer] _ in
                            animationLayer?.removeFromSuperlayer()
                        })
                        animationLayer.animateScale(from: 1.0, to: 0.01, duration: 0.2, removeOnCompletion: false)
                    } else {
                        animationLayer.removeFromSuperlayer()
                    }
                }
                if let lottieAnimationView = self.lottieAnimationView {
                    self.lottieAnimationView = nil
                    
                    if !transition.animation.isImmediate {
                        lottieAnimationView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false, completion: { [weak lottieAnimationView] _ in
                            lottieAnimationView?.removeFromSuperview()
                        })
                        lottieAnimationView.layer.animateScale(from: 1.0, to: 0.01, duration: 0.2, removeOnCompletion: false)
                    } else {
                        lottieAnimationView.removeFromSuperview()
                    }
                }
            }
            
            return size
        }
    }

    public func makeView() -> View {
        return View(frame: CGRect())
    }
    
    public func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<EnvironmentType>, transition: Transition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, state: state, environment: environment, transition: transition)
    }
}
