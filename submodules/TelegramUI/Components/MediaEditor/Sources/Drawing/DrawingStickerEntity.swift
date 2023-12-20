import Foundation
import UIKit
import Display
import AccountContext
import Postbox
import TelegramCore

private func entitiesPath() -> String {
    return NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0] + "/mediaEntities"
}

private func fullEntityMediaPath(_ path: String) -> String {
    return NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0] + "/mediaEntities/" + path
}

public final class DrawingStickerEntity: DrawingEntity, Codable {
    public enum Content: Equatable {
        public enum ImageType: Equatable {
            case sticker
            case rectangle
            case dualPhoto
        }
        public enum FileType: Equatable {
            public enum ReactionStyle: Int32 {
                case white
                case black
            }
            case sticker
            case reaction(MessageReaction.Reaction, ReactionStyle)
        }
        case file(TelegramMediaFile, FileType)
        case image(UIImage, ImageType)
        case animatedImage(Data, UIImage)
        case video(TelegramMediaFile)
        case dualVideoReference(Bool)
        case message([MessageId], TelegramMediaFile?, CGSize)
        
        public static func == (lhs: Content, rhs: Content) -> Bool {
            switch lhs {
            case let .file(lhsFile, lhsFileType):
                if case let .file(rhsFile, rhsFileType) = rhs {
                    return lhsFile.fileId == rhsFile.fileId && lhsFileType == rhsFileType
                } else {
                    return false
                }
            case let .image(lhsImage, lhsImageType):
                if case let .image(rhsImage, rhsImageType) = rhs {
                    return lhsImage === rhsImage && lhsImageType == rhsImageType
                } else {
                    return false
                }
            case let .animatedImage(lhsData, lhsThumbnailImage):
                if case let .animatedImage(rhsData, rhsThumbnailImage) = lhs {
                    return lhsData == rhsData && lhsThumbnailImage === rhsThumbnailImage
                } else {
                    return false
                }
            case let .video(lhsFile):
                if case let .video(rhsFile) = rhs {
                    return lhsFile.fileId == rhsFile.fileId
                } else {
                    return false
                }
            case let .dualVideoReference(isAdditional):
                if case .dualVideoReference(isAdditional) = rhs {
                    return true
                } else {
                    return false
                }
            case let .message(messageIds, innerFile, size):
                if case .message(messageIds, innerFile, size) = rhs {
                    return true
                } else {
                    return false
                }
            }
        }
    }
    private enum CodingKeys: String, CodingKey {
        case uuid
        case file
        case reaction
        case reactionStyle
        case imagePath
        case animatedImagePath
        case videoFile
        case isRectangle
        case isDualPhoto
        case dualVideo
        case isAdditionalVideo
        case messageIds
        case explicitSize
        case referenceDrawingSize
        case position
        case scale
        case rotation
        case mirrored
        case isExplicitlyStatic
        case renderImage
    }
    
    public var uuid: UUID
    public var content: Content
    
    public var referenceDrawingSize: CGSize
    public var position: CGPoint
    public var scale: CGFloat {
        didSet {
            if case let .file(_, type) = self.content, case .reaction = type {
                self.scale = max(0.59, min(1.77, self.scale))
            } else if case .message = self.content {
                self.scale = max(2.5, self.scale)
            }
        }
    }
    public var rotation: CGFloat
    public var mirrored: Bool
    
    public var isExplicitlyStatic: Bool
        
    public var color: DrawingColor = DrawingColor.clear
    public var lineWidth: CGFloat = 0.0
    
    public var secondaryRenderImage: UIImage?
    
    public var center: CGPoint {
        return self.position
    }
    
    public var baseSize: CGSize {
        let size = max(10.0, min(self.referenceDrawingSize.width, self.referenceDrawingSize.height) * 0.25)
        
        let dimensions: CGSize
        switch self.content {
        case let .image(image, _):
            dimensions = image.size
        case let .animatedImage(_, thumbnailImage):
            dimensions = thumbnailImage.size
        case let .file(file, type):
            if case .reaction = type {
                dimensions = CGSize(width: 512.0, height: 512.0)
            } else {
                dimensions = file.dimensions?.cgSize ?? CGSize(width: 512.0, height: 512.0)
            }
        case let .video(file):
            dimensions = file.dimensions?.cgSize ?? CGSize(width: 512.0, height: 512.0)
        case .dualVideoReference:
            dimensions = CGSize(width: 512.0, height: 512.0)
        case let .message(_, _, size):
            dimensions = size
        }
        
        let boundingSize = CGSize(width: size, height: size)
        return dimensions.fitted(boundingSize)
    }
    
    public var isAnimated: Bool {
        switch self.content {
        case let .file(file, type):
            if self.isExplicitlyStatic {
                return false
            } else {
                switch type {
                case .reaction:
                    return false
                default:
                    return file.isAnimatedSticker || file.isVideoSticker || file.mimeType == "video/webm"
                }
            }
        case .image:
            return false
        case .animatedImage:
            return true
        case .video:
            return true
        case .dualVideoReference:
            return true
        case .message:
            return !(self.renderSubEntities ?? []).isEmpty
        }
    }
    
    public var isRectangle: Bool {
        switch self.content {
        case let .image(_, imageType):
            return imageType == .rectangle
        case .video:
            return true
        case .message:
            return true
        default:
            return false
        }
    }
    
    public var isMedia: Bool {
        return false
    }
    
    public var renderImage: UIImage?
    public var renderSubEntities: [DrawingEntity]?
    
    public init(content: Content) {
        self.uuid = UUID()
        self.content = content
        
        self.referenceDrawingSize = .zero
        self.position = CGPoint()
        self.scale = 1.0
        self.rotation = 0.0
        self.mirrored = false
        
        self.isExplicitlyStatic = false
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.uuid = try container.decode(UUID.self, forKey: .uuid)
        if let messageIds = try container.decodeIfPresent([MessageId].self, forKey: .messageIds) {
            let size = try container.decodeIfPresent(CGSize.self, forKey: .explicitSize) ?? .zero
            self.content = .message(messageIds, nil, size)
        } else if let _ = try container.decodeIfPresent(Bool.self, forKey: .dualVideo) {
            let isAdditional = try container.decodeIfPresent(Bool.self, forKey: .isAdditionalVideo) ?? false
            self.content = .dualVideoReference(isAdditional)
        } else if let file = try container.decodeIfPresent(TelegramMediaFile.self, forKey: .file) {
            let fileType: Content.FileType
            if let reaction = try container.decodeIfPresent(MessageReaction.Reaction.self, forKey: .reaction) {
                var reactionStyle: Content.FileType.ReactionStyle = .white
                if let style = try container.decodeIfPresent(Int32.self, forKey: .reactionStyle) {
                    reactionStyle = DrawingStickerEntity.Content.FileType.ReactionStyle(rawValue: style) ?? .white
                }
                fileType = .reaction(reaction, reactionStyle)
            } else {
                fileType = .sticker
            }
            self.content = .file(file, fileType)
        } else if let imagePath = try container.decodeIfPresent(String.self, forKey: .imagePath), let image = UIImage(contentsOfFile: fullEntityMediaPath(imagePath)) {
            let isRectangle = try container.decodeIfPresent(Bool.self, forKey: .isRectangle) ?? false
            let isDualPhoto = try container.decodeIfPresent(Bool.self, forKey: .isDualPhoto) ?? false
            let imageType: Content.ImageType
            if isDualPhoto {
                imageType = .dualPhoto
            } else if isRectangle {
                imageType = .rectangle
            } else {
                imageType = .sticker
            }
            self.content = .image(image, imageType)
        } else if let dataPath = try container.decodeIfPresent(String.self, forKey: .animatedImagePath), let data = try? Data(contentsOf: URL(fileURLWithPath: fullEntityMediaPath(dataPath))), let imagePath = try container.decodeIfPresent(String.self, forKey: .imagePath), let thumbnailImage = UIImage(contentsOfFile: fullEntityMediaPath(imagePath)) {
            self.content = .animatedImage(data, thumbnailImage)
        } else if let file = try container.decodeIfPresent(TelegramMediaFile.self, forKey: .videoFile) {
            self.content = .video(file)
        } else {
            fatalError()
        }
        self.referenceDrawingSize = try container.decode(CGSize.self, forKey: .referenceDrawingSize)
        self.position = try container.decode(CGPoint.self, forKey: .position)
        self.scale = try container.decode(CGFloat.self, forKey: .scale)
        self.rotation = try container.decode(CGFloat.self, forKey: .rotation)
        self.mirrored = try container.decode(Bool.self, forKey: .mirrored)
        self.isExplicitlyStatic = try container.decodeIfPresent(Bool.self, forKey: .isExplicitlyStatic) ?? false
        
        if let renderImageData = try? container.decodeIfPresent(Data.self, forKey: .renderImage) {
            self.renderImage = UIImage(data: renderImageData)
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.uuid, forKey: .uuid)
        switch self.content {
        case let .file(file, fileType):
            try container.encode(file, forKey: .file)
            switch fileType {
            case let .reaction(reaction, reactionStyle):
                try container.encode(reaction, forKey: .reaction)
                try container.encode(reactionStyle.rawValue, forKey: .reactionStyle)
            default:
                break
            }
        case let .image(image, imageType):
            let imagePath = "\(self.uuid).png"
            let fullImagePath = fullEntityMediaPath(imagePath)
            if let imageData = image.pngData() {
                try? FileManager.default.createDirectory(atPath: entitiesPath(), withIntermediateDirectories: true)
                try? imageData.write(to: URL(fileURLWithPath: fullImagePath))
                try container.encodeIfPresent(imagePath, forKey: .imagePath)
            }
            switch imageType {
            case .dualPhoto:
                try container.encode(true, forKey: .isDualPhoto)
            case .rectangle:
                try container.encode(true, forKey: .isRectangle)
            default:
                break
            }
        case let .animatedImage(data, thumbnailImage):
            let dataPath = "\(self.uuid).heics"
            let fullDataPath = fullEntityMediaPath(dataPath)
            try? FileManager.default.createDirectory(atPath: entitiesPath(), withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: fullDataPath))
            try container.encodeIfPresent(dataPath, forKey: .animatedImagePath)
            
            let imagePath = "\(self.uuid).png"
            let fullImagePath = fullEntityMediaPath(imagePath)
            if let imageData = thumbnailImage.pngData() {
                try? FileManager.default.createDirectory(atPath: entitiesPath(), withIntermediateDirectories: true)
                try? imageData.write(to: URL(fileURLWithPath: fullImagePath))
                try container.encodeIfPresent(imagePath, forKey: .imagePath)
            }
        case let .video(file):
            try container.encode(file, forKey: .videoFile)
        case let .dualVideoReference(isAdditional):
            try container.encode(true, forKey: .dualVideo)
            try container.encode(isAdditional, forKey: .isAdditionalVideo)
        case let .message(messageIds, innerFile, size):
            try container.encode(messageIds, forKey: .messageIds)
            let _ = innerFile
            try container.encode(size, forKey: .explicitSize)
        }
        try container.encode(self.referenceDrawingSize, forKey: .referenceDrawingSize)
        try container.encode(self.position, forKey: .position)
        try container.encode(self.scale, forKey: .scale)
        try container.encode(self.rotation, forKey: .rotation)
        try container.encode(self.mirrored, forKey: .mirrored)
        try container.encode(self.isExplicitlyStatic, forKey: .isExplicitlyStatic)
        
        if let renderImage, let data = renderImage.pngData() {
            try container.encode(data, forKey: .renderImage)
        }
    }
        
    public func duplicate(copy: Bool) -> DrawingEntity {
        let newEntity = DrawingStickerEntity(content: self.content)
        if copy {
            newEntity.uuid = self.uuid
        }
        newEntity.referenceDrawingSize = self.referenceDrawingSize
        newEntity.position = self.position
        newEntity.scale = self.scale
        newEntity.rotation = self.rotation
        newEntity.mirrored = self.mirrored
        newEntity.isExplicitlyStatic = self.isExplicitlyStatic
        return newEntity
    }
    
    public func isEqual(to other: DrawingEntity) -> Bool {
        guard let other = other as? DrawingStickerEntity else {
            return false
        }
        if self.uuid != other.uuid {
            return false
        }
        if self.content != other.content {
            return false
        }
        if self.referenceDrawingSize != other.referenceDrawingSize {
            return false
        }
        if self.position != other.position {
            return false
        }
        if self.scale != other.scale {
            return false
        }
        if self.rotation != other.rotation {
            return false
        }
        if self.mirrored != other.mirrored {
            return false
        }
        if self.isExplicitlyStatic != other.isExplicitlyStatic {
            return false
        }
        return true
    }
}
