import Foundation
import UIKit
import Display
import AsyncDisplayKit
import ComponentFlow
import SwiftSignalKit
import ViewControllerComponent
import ComponentDisplayAdapters
import TelegramPresentationData
import AccountContext
import TelegramCore
import MultilineTextComponent
import Postbox
import SolidRoundedButtonComponent
import PresentationDataUtils
import Markdown
import UndoUI
import PremiumUI

private final class ChatFolderLinkPreviewScreenComponent: Component {
    typealias EnvironmentType = ViewControllerComponentContainer.Environment
    
    let context: AccountContext
    let slug: String
    let linkContents: ChatFolderLinkContents?
    
    init(
        context: AccountContext,
        slug: String,
        linkContents: ChatFolderLinkContents?
    ) {
        self.context = context
        self.slug = slug
        self.linkContents = linkContents
    }
    
    static func ==(lhs: ChatFolderLinkPreviewScreenComponent, rhs: ChatFolderLinkPreviewScreenComponent) -> Bool {
        if lhs.context !== rhs.context {
            return false
        }
        if lhs.slug != rhs.slug {
            return false
        }
        if lhs.linkContents !== rhs.linkContents {
            return false
        }
        return true
    }
    
    private struct ItemLayout: Equatable {
        var containerSize: CGSize
        var containerInset: CGFloat
        var bottomInset: CGFloat
        var topInset: CGFloat
        
        init(containerSize: CGSize, containerInset: CGFloat, bottomInset: CGFloat, topInset: CGFloat) {
            self.containerSize = containerSize
            self.containerInset = containerInset
            self.bottomInset = bottomInset
            self.topInset = topInset
        }
    }
    
    private final class ScrollView: UIScrollView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            return super.hitTest(point, with: event)
        }
    }
    
    final class AnimationHint {
        init() {
        }
    }
    
    final class View: UIView, UIScrollViewDelegate {
        private let dimView: UIView
        private let backgroundLayer: SimpleLayer
        private let navigationBarContainer: SparseContainerView
        private let scrollView: ScrollView
        private let scrollContentClippingView: SparseContainerView
        private let scrollContentView: UIView
        
        private let topIcon = ComponentView<Empty>()
        
        private let title = ComponentView<Empty>()
        private let leftButton = ComponentView<Empty>()
        private let descriptionText = ComponentView<Empty>()
        private let actionButton = ComponentView<Empty>()
        
        private let listHeaderText = ComponentView<Empty>()
        private let listHeaderAction = ComponentView<Empty>()
        private let itemContainerView: UIView
        private var items: [AnyHashable: ComponentView<Empty>] = [:]
        
        private var selectedItems = Set<EnginePeer.Id>()
        
        private let bottomOverscrollLimit: CGFloat
        
        private var ignoreScrolling: Bool = false
        
        private var component: ChatFolderLinkPreviewScreenComponent?
        private weak var state: EmptyComponentState?
        private var environment: ViewControllerComponentContainer.Environment?
        private var itemLayout: ItemLayout?
        
        private var topOffsetDistance: CGFloat?
        
        private var joinDisposable: Disposable?
        
        override init(frame: CGRect) {
            self.bottomOverscrollLimit = 200.0
            
            self.dimView = UIView()
            
            self.backgroundLayer = SimpleLayer()
            self.backgroundLayer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            self.backgroundLayer.cornerRadius = 10.0
            
            self.navigationBarContainer = SparseContainerView()
            
            self.scrollView = ScrollView()
            
            self.scrollContentClippingView = SparseContainerView()
            self.scrollContentClippingView.clipsToBounds = true
            
            self.scrollContentView = UIView()
            
            self.itemContainerView = UIView()
            self.itemContainerView.clipsToBounds = true
            self.itemContainerView.layer.cornerRadius = 10.0
            
            super.init(frame: frame)
            
            self.addSubview(self.dimView)
            self.layer.addSublayer(self.backgroundLayer)
            
            self.addSubview(self.navigationBarContainer)
            
            self.scrollView.delaysContentTouches = true
            self.scrollView.canCancelContentTouches = true
            self.scrollView.clipsToBounds = false
            if #available(iOSApplicationExtension 11.0, iOS 11.0, *) {
                self.scrollView.contentInsetAdjustmentBehavior = .never
            }
            if #available(iOS 13.0, *) {
                self.scrollView.automaticallyAdjustsScrollIndicatorInsets = false
            }
            self.scrollView.showsVerticalScrollIndicator = false
            self.scrollView.showsHorizontalScrollIndicator = false
            self.scrollView.alwaysBounceHorizontal = false
            self.scrollView.alwaysBounceVertical = true
            self.scrollView.scrollsToTop = false
            self.scrollView.delegate = self
            self.scrollView.clipsToBounds = true
            
            self.addSubview(self.scrollContentClippingView)
            self.scrollContentClippingView.addSubview(self.scrollView)
            
            self.scrollView.addSubview(self.scrollContentView)
            
            self.scrollContentView.addSubview(self.itemContainerView)
            
            self.dimView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.dimTapGesture(_:))))
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        deinit {
            self.joinDisposable?.dispose()
        }
        
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if !self.ignoreScrolling {
                self.updateScrolling(transition: .immediate)
            }
        }
        
        func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            guard let itemLayout = self.itemLayout, let topOffsetDistance = self.topOffsetDistance else {
                return
            }
            
            var topOffset = -self.scrollView.bounds.minY + itemLayout.topInset
            topOffset = max(0.0, topOffset)
            
            if topOffset < topOffsetDistance {
                targetContentOffset.pointee.y = scrollView.contentOffset.y
                scrollView.setContentOffset(CGPoint(x: 0.0, y: itemLayout.topInset), animated: true)
            }
        }
        
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            if !self.bounds.contains(point) {
                return nil
            }
            if !self.backgroundLayer.frame.contains(point) {
                return self.dimView
            }
            
            if let result = self.navigationBarContainer.hitTest(self.convert(point, to: self.navigationBarContainer), with: event) {
                return result
            }
            
            let result = super.hitTest(point, with: event)
            return result
        }
        
        @objc private func dimTapGesture(_ recognizer: UITapGestureRecognizer) {
            if case .ended = recognizer.state {
                guard let environment = self.environment, let controller = environment.controller() else {
                    return
                }
                controller.dismiss()
            }
        }
        
        private func updateScrolling(transition: Transition) {
            guard let environment = self.environment, let controller = environment.controller(), let itemLayout = self.itemLayout else {
                return
            }
            var topOffset = -self.scrollView.bounds.minY + itemLayout.topInset
            topOffset = max(0.0, topOffset)
            transition.setTransform(layer: self.backgroundLayer, transform: CATransform3DMakeTranslation(0.0, topOffset + itemLayout.containerInset, 0.0))
            
            transition.setPosition(view: self.navigationBarContainer, position: CGPoint(x: 0.0, y: topOffset + itemLayout.containerInset))
            
            let topOffsetDistance: CGFloat = min(200.0, floor(itemLayout.containerSize.height * 0.25))
            self.topOffsetDistance = topOffsetDistance
            var topOffsetFraction = topOffset / topOffsetDistance
            topOffsetFraction = max(0.0, min(1.0, topOffsetFraction))
            
            let transitionFactor: CGFloat = 1.0 - topOffsetFraction
            controller.updateModalStyleOverlayTransitionFactor(transitionFactor, transition: transition.containedViewLayoutTransition)
        }
        
        func animateIn() {
            self.dimView.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3)
            let animateOffset: CGFloat = self.backgroundLayer.frame.minY
            self.scrollContentClippingView.layer.animatePosition(from: CGPoint(x: 0.0, y: animateOffset), to: CGPoint(), duration: 0.5, timingFunction: kCAMediaTimingFunctionSpring, additive: true)
            self.backgroundLayer.animatePosition(from: CGPoint(x: 0.0, y: animateOffset), to: CGPoint(), duration: 0.5, timingFunction: kCAMediaTimingFunctionSpring, additive: true)
            self.navigationBarContainer.layer.animatePosition(from: CGPoint(x: 0.0, y: animateOffset), to: CGPoint(), duration: 0.5, timingFunction: kCAMediaTimingFunctionSpring, additive: true)
            if let actionButtonView = self.actionButton.view {
                actionButtonView.layer.animatePosition(from: CGPoint(x: 0.0, y: animateOffset), to: CGPoint(), duration: 0.5, timingFunction: kCAMediaTimingFunctionSpring, additive: true)
            }
        }
        
        func animateOut(completion: @escaping () -> Void) {
            if let controller = self.environment?.controller() {
                controller.updateModalStyleOverlayTransitionFactor(0.0, transition: .animated(duration: 0.3, curve: .easeInOut))
            }
            
            let animateOffset: CGFloat = self.bounds.height - self.backgroundLayer.frame.minY
            
            self.dimView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false)
            self.scrollContentClippingView.layer.animatePosition(from: CGPoint(), to: CGPoint(x: 0.0, y: animateOffset), duration: 0.3, timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue, removeOnCompletion: false, additive: true, completion: { _ in
                completion()
            })
            self.backgroundLayer.animatePosition(from: CGPoint(), to: CGPoint(x: 0.0, y: animateOffset), duration: 0.3, timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue, removeOnCompletion: false, additive: true)
            self.navigationBarContainer.layer.animatePosition(from: CGPoint(), to: CGPoint(x: 0.0, y: animateOffset), duration: 0.3, timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue, removeOnCompletion: false, additive: true)
            if let actionButtonView = self.actionButton.view {
                actionButtonView.layer.animatePosition(from: CGPoint(), to: CGPoint(x: 0.0, y: animateOffset), duration: 0.3, timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue, removeOnCompletion: false, additive: true)
            }
        }
        
        func update(component: ChatFolderLinkPreviewScreenComponent, availableSize: CGSize, state: EmptyComponentState, environment: Environment<ViewControllerComponentContainer.Environment>, transition: Transition) -> CGSize {
            let animationHint = transition.userData(AnimationHint.self)
            
            var contentTransition = transition
            if animationHint != nil {
                contentTransition = .immediate
            }
            
            let environment = environment[ViewControllerComponentContainer.Environment.self].value
            let themeUpdated = self.environment?.theme !== environment.theme
            
            let resetScrolling = self.scrollView.bounds.width != availableSize.width
            
            let sideInset: CGFloat = 16.0
            
            if self.component?.linkContents == nil, let linkContents = component.linkContents {
                for peer in linkContents.peers {
                    self.selectedItems.insert(peer.id)
                }
            }
            
            self.component = component
            self.state = state
            self.environment = environment
            
            if themeUpdated {
                self.dimView.backgroundColor = UIColor(white: 0.0, alpha: 0.5)
                self.backgroundLayer.backgroundColor = environment.theme.list.blocksBackgroundColor.cgColor
                self.itemContainerView.backgroundColor = environment.theme.list.itemBlocksBackgroundColor
            }
            
            transition.setFrame(view: self.dimView, frame: CGRect(origin: CGPoint(), size: availableSize))
            
            var contentHeight: CGFloat = 0.0
            
            let leftButtonSize = self.leftButton.update(
                transition: contentTransition,
                component: AnyComponent(Button(
                    content: AnyComponent(Text(text: environment.strings.Common_Cancel, font: Font.regular(17.0), color: environment.theme.list.itemAccentColor)),
                    action: { [weak self] in
                        guard let self, let controller = self.environment?.controller() else {
                            return
                        }
                        controller.dismiss()
                    }
                ).minSize(CGSize(width: 44.0, height: 56.0))),
                environment: {},
                containerSize: CGSize(width: 120.0, height: 100.0)
            )
            let leftButtonFrame = CGRect(origin: CGPoint(x: 16.0, y: 0.0), size: leftButtonSize)
            if let leftButtonView = self.leftButton.view {
                if leftButtonView.superview == nil {
                    self.navigationBarContainer.addSubview(leftButtonView)
                }
                transition.setFrame(view: leftButtonView, frame: leftButtonFrame)
            }
            
            let titleString: String
            if let linkContents = component.linkContents {
                //TODO:localize
                if linkContents.localFilterId != nil {
                    if self.selectedItems.count == 1 {
                        titleString = "Add \(self.selectedItems.count) chat"
                    } else {
                        titleString = "Add \(self.selectedItems.count) chats"
                    }
                } else {
                    titleString = "Add Folder"
                }
            } else {
                titleString = " "
            }
            let titleSize = self.title.update(
                transition: .immediate,
                component: AnyComponent(MultilineTextComponent(
                    text: .plain(NSAttributedString(string: titleString, font: Font.semibold(17.0), textColor: environment.theme.list.itemPrimaryTextColor))
                )),
                environment: {},
                containerSize: CGSize(width: availableSize.width - leftButtonFrame.maxX * 2.0, height: 100.0)
            )
            let titleFrame = CGRect(origin: CGPoint(x: floor((availableSize.width - titleSize.width) * 0.5), y: 18.0), size: titleSize)
            if let titleView = self.title.view {
                if titleView.superview == nil {
                    self.navigationBarContainer.addSubview(titleView)
                }
                contentTransition.setFrame(view: titleView, frame: titleFrame)
            }
            
            contentHeight += 44.0
            contentHeight += 14.0
            
            var topBadge: String?
            if let linkContents = component.linkContents, linkContents.localFilterId != nil {
                topBadge = "+\(linkContents.peers.count)"
            }
            
            let topIconSize = self.topIcon.update(
                transition: contentTransition,
                component: AnyComponent(ChatFolderLinkHeaderComponent(
                    theme: environment.theme,
                    strings: environment.strings,
                    title: component.linkContents?.title ?? "Folder",
                    badge: topBadge
                )),
                environment: {},
                containerSize: CGSize(width: availableSize.width - sideInset, height: 1000.0)
            )
            let topIconFrame = CGRect(origin: CGPoint(x: floor((availableSize.width - topIconSize.width) * 0.5), y: contentHeight), size: topIconSize)
            if let topIconView = self.topIcon.view {
                if topIconView.superview == nil {
                    self.scrollContentView.addSubview(topIconView)
                }
                contentTransition.setFrame(view: topIconView, frame: topIconFrame)
                topIconView.isHidden = component.linkContents == nil
            }
            
            contentHeight += topIconSize.height
            contentHeight += 20.0
            
            let text: String
            if let linkContents = component.linkContents {
                if linkContents.localFilterId == nil {
                    text = "Do you want to add a new chat folder\nand join its groups and channels?"
                } else {
                    let chatCountString: String
                    if self.selectedItems.count == 1 {
                        chatCountString = "1 chat"
                    } else {
                        chatCountString = "\(self.selectedItems.count) chats"
                    }
                    if let title = linkContents.title {
                        text = "Do you want to add **\(chatCountString)** to your\nfolder **\(title)**?"
                    } else {
                        text = "Do you want to add **\(chatCountString)** chats to your\nfolder?"
                    }
                }
            } else {
                text = " "
            }
            
            let body = MarkdownAttributeSet(font: Font.regular(15.0), textColor: environment.theme.list.freeTextColor)
            let bold = MarkdownAttributeSet(font: Font.semibold(15.0), textColor: environment.theme.list.freeTextColor)
            
            let descriptionTextSize = self.descriptionText.update(
                transition: .immediate,
                component: AnyComponent(MultilineTextComponent(
                    text: .markdown(text: text, attributes: MarkdownAttributes(
                        body: body,
                        bold: bold,
                        link: body,
                        linkAttribute: { _ in nil }
                    )),
                    horizontalAlignment: .center,
                    maximumNumberOfLines: 0
                )),
                environment: {},
                containerSize: CGSize(width: availableSize.width - sideInset * 2.0 - 16.0 * 2.0, height: 1000.0)
            )
            let descriptionTextFrame = CGRect(origin: CGPoint(x: floor((availableSize.width - descriptionTextSize.width) * 0.5), y: contentHeight), size: descriptionTextSize)
            if let descriptionTextView = self.descriptionText.view {
                if descriptionTextView.superview == nil {
                    self.scrollContentView.addSubview(descriptionTextView)
                }
                contentTransition.setFrame(view: descriptionTextView, frame: descriptionTextFrame)
            }
            
            contentHeight += descriptionTextFrame.height
            contentHeight += 39.0
            
            var singleItemHeight: CGFloat = 0.0
            
            var itemsHeight: CGFloat = 0.0
            var validIds: [AnyHashable] = []
            if let linkContents = component.linkContents {
                for i in 0 ..< linkContents.peers.count {
                    let peer = linkContents.peers[i]
                    
                    for _ in 0 ..< 1 {
                        //let id: AnyHashable = AnyHashable("\(peer.id)_\(j)")
                        let id = AnyHashable(peer.id)
                        validIds.append(id)
                        
                        let item: ComponentView<Empty>
                        var itemTransition = transition
                        if let current = self.items[id] {
                            item = current
                        } else {
                            itemTransition = .immediate
                            item = ComponentView()
                            self.items[id] = item
                        }
                        
                        let itemSize = item.update(
                            transition: itemTransition,
                            component: AnyComponent(PeerListItemComponent(
                                context: component.context,
                                theme: environment.theme,
                                strings: environment.strings,
                                sideInset: 0.0,
                                title: peer.displayTitle(strings: environment.strings, displayOrder: .firstLast),
                                peer: peer,
                                subtitle: nil,
                                selectionState: .editing(isSelected: self.selectedItems.contains(peer.id), isTinted: linkContents.alreadyMemberPeerIds.contains(peer.id)),
                                hasNext: i != linkContents.peers.count - 1,
                                action: { [weak self] peer in
                                    guard let self, let component = self.component, let linkContents = component.linkContents, let controller = self.environment?.controller() else {
                                        return
                                    }
                                    
                                    if linkContents.alreadyMemberPeerIds.contains(peer.id) {
                                        let presentationData = component.context.sharedContext.currentPresentationData.with { $0 }
                                        let text: String
                                        if case let .channel(channel) = peer, case .broadcast = channel.info {
                                            text = "You are already a member of this channel."
                                        } else {
                                            text = "You are already a member of this group."
                                        }
                                        controller.present(UndoOverlayController(presentationData: presentationData, content: .peers(context: component.context, peers: [peer], title: nil, text: text, customUndoText: nil), elevatedLayout: false, action: { _ in true }), in: .current)
                                    } else {
                                        if self.selectedItems.contains(peer.id) {
                                            self.selectedItems.remove(peer.id)
                                        } else {
                                            self.selectedItems.insert(peer.id)
                                        }
                                        self.state?.updated(transition: Transition(animation: .curve(duration: 0.3, curve: .easeInOut)))
                                    }
                                }
                            )),
                            environment: {},
                            containerSize: CGSize(width: availableSize.width - sideInset * 2.0, height: 1000.0)
                        )
                        let itemFrame = CGRect(origin: CGPoint(x: 0.0, y: itemsHeight), size: itemSize)
                        
                        if let itemView = item.view {
                            if itemView.superview == nil {
                                self.itemContainerView.addSubview(itemView)
                            }
                            itemTransition.setFrame(view: itemView, frame: itemFrame)
                        }
                        
                        itemsHeight += itemSize.height
                        singleItemHeight = itemSize.height
                    }
                }
            }
            
            var removeIds: [AnyHashable] = []
            for (id, item) in self.items {
                if !validIds.contains(id) {
                    removeIds.append(id)
                    item.view?.removeFromSuperview()
                }
            }
            for id in removeIds {
                self.items.removeValue(forKey: id)
            }
            
            let listHeaderTitle: String
            if self.selectedItems.count == 1 {
                listHeaderTitle = "1 CHAT IN FOLDER TO JOIN"
            } else {
                listHeaderTitle = "\(self.selectedItems.count) CHATS IN FOLDER TO JOIN"
            }
            
            let listHeaderActionTitle: String
            if self.selectedItems.count == self.items.count {
                listHeaderActionTitle = "DESELECT ALL"
            } else {
                listHeaderActionTitle = "SELECT ALL"
            }
            
            let listHeaderBody = MarkdownAttributeSet(font: Font.with(size: 13.0, design: .regular, traits: [.monospacedNumbers]), textColor: environment.theme.list.freeTextColor)
            let listHeaderActionBody = MarkdownAttributeSet(font: Font.with(size: 13.0, design: .regular, traits: [.monospacedNumbers]), textColor: environment.theme.list.itemAccentColor)
            
            let listHeaderTextSize = self.listHeaderText.update(
                transition: .immediate,
                component: AnyComponent(MultilineTextComponent(
                    text: .markdown(
                        text: listHeaderTitle,
                        attributes: MarkdownAttributes(
                            body: listHeaderBody,
                            bold: listHeaderBody,
                            link: listHeaderBody,
                            linkAttribute: { _ in nil }
                        )
                    )
                )),
                environment: {},
                containerSize: CGSize(width: availableSize.width - sideInset * 2.0 - 15.0, height: 1000.0)
            )
            if let listHeaderTextView = self.listHeaderText.view {
                if listHeaderTextView.superview == nil {
                    listHeaderTextView.layer.anchorPoint = CGPoint()
                    self.scrollContentView.addSubview(listHeaderTextView)
                }
                let listHeaderTextFrame = CGRect(origin: CGPoint(x: sideInset + 15.0, y: contentHeight), size: listHeaderTextSize)
                contentTransition.setPosition(view: listHeaderTextView, position: listHeaderTextFrame.origin)
                listHeaderTextView.bounds = CGRect(origin: CGPoint(), size: listHeaderTextFrame.size)
                listHeaderTextView.isHidden = component.linkContents == nil
            }
            
            let listHeaderActionSize = self.listHeaderAction.update(
                transition: .immediate,
                component: AnyComponent(Button(
                    content: AnyComponent(MultilineTextComponent(
                        text: .markdown(
                            text: listHeaderActionTitle,
                            attributes: MarkdownAttributes(
                                body: listHeaderActionBody,
                                bold: listHeaderActionBody,
                                link: listHeaderActionBody,
                                linkAttribute: { _ in nil }
                            )
                        )
                    )),
                    action: { [weak self] in
                        guard let self, let component = self.component, let linkContents = component.linkContents else {
                            return
                        }
                        if self.selectedItems.count != linkContents.peers.count {
                            for peer in linkContents.peers {
                                self.selectedItems.insert(peer.id)
                            }
                        } else {
                            self.selectedItems.removeAll()
                            for peerId in linkContents.alreadyMemberPeerIds {
                                self.selectedItems.insert(peerId)
                            }
                        }
                        self.state?.updated(transition: .immediate)
                    }
                )),
                environment: {},
                containerSize: CGSize(width: availableSize.width - sideInset * 2.0 - 15.0, height: 1000.0)
            )
            if let listHeaderActionView = self.listHeaderAction.view {
                if listHeaderActionView.superview == nil {
                    listHeaderActionView.layer.anchorPoint = CGPoint(x: 1.0, y: 0.0)
                    self.scrollContentView.addSubview(listHeaderActionView)
                }
                let listHeaderActionFrame = CGRect(origin: CGPoint(x: availableSize.width - sideInset - 15.0 - listHeaderActionSize.width, y: contentHeight), size: listHeaderActionSize)
                contentTransition.setPosition(view: listHeaderActionView, position: CGPoint(x: listHeaderActionFrame.maxX, y: listHeaderActionFrame.minY))
                listHeaderActionView.bounds = CGRect(origin: CGPoint(), size: listHeaderActionFrame.size)
                listHeaderActionView.isHidden = component.linkContents == nil
            }
            
            contentHeight += listHeaderTextSize.height
            contentHeight += 6.0
            
            contentTransition.setFrame(view: self.itemContainerView, frame: CGRect(origin: CGPoint(x: sideInset, y: contentHeight), size: CGSize(width: availableSize.width - sideInset * 2.0, height: itemsHeight)))
            
            var initialContentHeight = contentHeight
            initialContentHeight += min(itemsHeight, floor(singleItemHeight * 2.5))
            
            contentHeight += itemsHeight
            contentHeight += 24.0
            initialContentHeight += 24.0
            
            let actionButtonTitle: String
            if let linkContents = component.linkContents {
                if linkContents.localFilterId != nil {
                    if self.selectedItems.isEmpty {
                        actionButtonTitle = "Do Not Join Any Chats"
                    } else {
                        actionButtonTitle = "Join Chats"
                    }
                } else {
                    actionButtonTitle = "Add Folder"
                }
            } else {
                actionButtonTitle = " "
            }
            
            let actionButtonSize = self.actionButton.update(
                transition: transition,
                component: AnyComponent(SolidRoundedButtonComponent(
                    title: actionButtonTitle,
                    badge: (self.selectedItems.isEmpty) ? nil : "\(self.selectedItems.count)",
                    theme: SolidRoundedButtonComponent.Theme(theme: environment.theme),
                    font: .bold,
                    fontSize: 17.0,
                    height: 50.0,
                    cornerRadius: 11.0,
                    gloss: false,
                    isEnabled: !self.selectedItems.isEmpty || component.linkContents?.localFilterId != nil,
                    animationName: nil,
                    iconPosition: .right,
                    iconSpacing: 4.0,
                    isLoading: component.linkContents == nil,
                    action: { [weak self] in
                        guard let self, let component = self.component, let controller = self.environment?.controller() else {
                            return
                        }
                        
                        if let _ = component.linkContents {
                            if self.joinDisposable == nil, !self.selectedItems.isEmpty {
                                self.joinDisposable = (component.context.engine.peers.joinChatFolderLink(slug: component.slug, peerIds: Array(self.selectedItems))
                                |> deliverOnMainQueue).start(error: { [weak self] error in
                                    guard let self, let component = self.component, let controller = self.environment?.controller() else {
                                        return
                                    }
                                    
                                    switch error {
                                    case .generic:
                                        controller.dismiss()
                                    case .limitExceeded:
                                        //TODO:localize
                                        let limitController = PremiumLimitScreen(context: component.context, subject: .folders, count: 5, action: {})
                                        controller.push(limitController)
                                        controller.dismiss()
                                    }
                                }, completed: { [weak self] in
                                    guard let self, let controller = self.environment?.controller() else {
                                        return
                                    }
                                    controller.dismiss()
                                })
                            } else {
                                controller.dismiss()
                            }
                        }
                        
                        /*if self.selectedItems.isEmpty {
                            controller.dismiss()
                        } else if let link = component.link {
                            let selectedPeers = component.peers.filter { self.selectedItems.contains($0.id) }
                            
                            let _ = enqueueMessagesToMultiplePeers(account: component.context.account, peerIds: Array(self.selectedItems), threadIds: [:], messages: [.message(text: link, attributes: [], inlineStickers: [:], mediaReference: nil, replyToMessageId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])]).start()
                            let text: String
                            if selectedPeers.count == 1 {
                                text = environment.strings.Conversation_ShareLinkTooltip_Chat_One(selectedPeers[0].displayTitle(strings: environment.strings, displayOrder: .firstLast).replacingOccurrences(of: "*", with: "")).string
                            } else if selectedPeers.count == 2 {
                                text = environment.strings.Conversation_ShareLinkTooltip_TwoChats_One(selectedPeers[0].displayTitle(strings: environment.strings, displayOrder: .firstLast).replacingOccurrences(of: "*", with: ""), selectedPeers[1].displayTitle(strings: environment.strings, displayOrder: .firstLast).replacingOccurrences(of: "*", with: "")).string
                            } else {
                                text = environment.strings.Conversation_ShareLinkTooltip_ManyChats_One(selectedPeers[0].displayTitle(strings: environment.strings, displayOrder: .firstLast).replacingOccurrences(of: "*", with: ""), "\(selectedPeers.count - 1)").string
                            }
                            
                            let presentationData = component.context.sharedContext.currentPresentationData.with { $0 }
                            controller.present(UndoOverlayController(presentationData: presentationData, content: .forward(savedMessages: false, text: text), elevatedLayout: false, action: { _ in return false }), in: .window(.root))
                            
                            controller.dismiss()
                        } else {
                            controller.dismiss()
                        }*/
                    }
                )),
                environment: {},
                containerSize: CGSize(width: availableSize.width - sideInset * 2.0, height: 50.0)
            )
            let bottomPanelHeight = 14.0 + environment.safeInsets.bottom + actionButtonSize.height
            let actionButtonFrame = CGRect(origin: CGPoint(x: sideInset, y: availableSize.height - bottomPanelHeight), size: actionButtonSize)
            if let actionButtonView = self.actionButton.view {
                if actionButtonView.superview == nil {
                    self.addSubview(actionButtonView)
                }
                transition.setFrame(view: actionButtonView, frame: actionButtonFrame)
            }
            
            if let controller = environment.controller() {
                let subLayout = ContainerViewLayout(
                    size: availableSize, metrics: environment.metrics, deviceMetrics: environment.deviceMetrics, intrinsicInsets: UIEdgeInsets(top: 0.0, left: sideInset - 12.0, bottom: bottomPanelHeight, right: sideInset),
                    safeInsets: UIEdgeInsets(),
                    additionalInsets: UIEdgeInsets(),
                    statusBarHeight: nil,
                    inputHeight: nil,
                    inputHeightIsInteractivellyChanging: false,
                    inVoiceOver: false
                )
                controller.presentationContext.containerLayoutUpdated(subLayout, transition: transition.containedViewLayoutTransition)
            }
            
            contentHeight += bottomPanelHeight
            initialContentHeight += bottomPanelHeight
            
            let containerInset: CGFloat = environment.statusBarHeight + 10.0
            let topInset: CGFloat = max(0.0, availableSize.height - containerInset - initialContentHeight)
            
            let scrollContentHeight = max(topInset + contentHeight, availableSize.height - containerInset)
            
            self.scrollContentClippingView.layer.cornerRadius = 10.0
            
            self.itemLayout = ItemLayout(containerSize: availableSize, containerInset: containerInset, bottomInset: environment.safeInsets.bottom, topInset: topInset)
            
            transition.setFrame(view: self.scrollContentView, frame: CGRect(origin: CGPoint(x: 0.0, y: topInset + containerInset), size: CGSize(width: availableSize.width, height: contentHeight)))
            
            transition.setPosition(layer: self.backgroundLayer, position: CGPoint(x: availableSize.width / 2.0, y: availableSize.height / 2.0))
            transition.setBounds(layer: self.backgroundLayer, bounds: CGRect(origin: CGPoint(), size: availableSize))
            
            let scrollClippingFrame = CGRect(origin: CGPoint(x: sideInset, y: containerInset + 56.0), size: CGSize(width: availableSize.width - sideInset * 2.0, height: actionButtonFrame.minY - 24.0 - (containerInset + 56.0)))
            transition.setPosition(view: self.scrollContentClippingView, position: scrollClippingFrame.center)
            transition.setBounds(view: self.scrollContentClippingView, bounds: CGRect(origin: CGPoint(x: scrollClippingFrame.minX, y: scrollClippingFrame.minY), size: scrollClippingFrame.size))
            
            self.ignoreScrolling = true
            transition.setFrame(view: self.scrollView, frame: CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: CGSize(width: availableSize.width, height: availableSize.height - containerInset)))
            let contentSize = CGSize(width: availableSize.width, height: scrollContentHeight)
            if contentSize != self.scrollView.contentSize {
                self.scrollView.contentSize = contentSize
            }
            if resetScrolling {
                self.scrollView.bounds = CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: availableSize)
            }
            self.ignoreScrolling = false
            self.updateScrolling(transition: transition)
            
            return availableSize
        }
    }
    
    func makeView() -> View {
        return View(frame: CGRect())
    }
    
    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<ViewControllerComponentContainer.Environment>, transition: Transition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, state: state, environment: environment, transition: transition)
    }
}

public class ChatFolderLinkPreviewScreen: ViewControllerComponentContainer {
    private let context: AccountContext
    private var linkContents: ChatFolderLinkContents?
    private var linkContentsDisposable: Disposable?
    
    private var isDismissed: Bool = false
    
    public init(context: AccountContext, slug: String) {
        self.context = context
        
        super.init(context: context, component: ChatFolderLinkPreviewScreenComponent(context: context, slug: slug, linkContents: nil), navigationBarAppearance: .none)
        
        self.statusBar.statusBarStyle = .Ignore
        self.navigationPresentation = .flatModal
        self.blocksBackgroundWhenInOverlay = true
        
        self.linkContentsDisposable = (context.engine.peers.checkChatFolderLink(slug: slug)
        |> delay(0.2, queue: .mainQueue())
        |> deliverOnMainQueue).start(next: { [weak self] result in
            guard let self else {
                return
            }
            self.linkContents = result
            self.updateComponent(component: AnyComponent(ChatFolderLinkPreviewScreenComponent(context: context, slug: slug, linkContents: result)), transition: Transition(animation: .curve(duration: 0.2, curve: .easeInOut)).withUserData(ChatFolderLinkPreviewScreenComponent.AnimationHint()))
        }, error: { [weak self] _ in
            guard let self else {
                return
            }
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            self.present(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: "The folder link has expired."), elevatedLayout: false, action: { _ in true }), in: .window(.root))
            self.dismiss()
        })
        
        self.automaticallyControlPresentationContextLayout = false
    }
    
    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        self.linkContentsDisposable?.dispose()
    }
    
    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
    }
    
    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        self.view.disablesInteractiveModalDismiss = true
        
        if let componentView = self.node.hostView.componentView as? ChatFolderLinkPreviewScreenComponent.View {
            componentView.animateIn()
        }
    }
    
    override public func dismiss(completion: (() -> Void)? = nil) {
        if !self.isDismissed {
            self.isDismissed = true
            
            if let componentView = self.node.hostView.componentView as? ChatFolderLinkPreviewScreenComponent.View {
                componentView.animateOut(completion: { [weak self] in
                    completion?()
                    self?.dismiss(animated: false)
                })
            } else {
                self.dismiss(animated: false)
            }
        }
    }
}
