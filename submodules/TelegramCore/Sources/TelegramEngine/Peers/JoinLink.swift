import Postbox
import SwiftSignalKit
import TelegramApi
import MtProtoKit


public enum JoinLinkError {
    case generic
    case tooMuchJoined
    case tooMuchUsers
}

func apiUpdatesGroups(_ updates: Api.Updates) -> [Api.Chat] {
    switch updates {
        case let .updates( _, _, chats, _, _):
            return chats
        case let .updatesCombined(_, _, chats, _, _, _):
            return chats
        default:
            return []
    }
}

public enum ExternalJoiningChatState {
    public struct InviteFlags : Equatable {
        public let isChannel: Bool
        public let isBroadcast: Bool
        public let isPublic: Bool
        public let isMegagroup: Bool
        public let requestNeeded: Bool
    }
    
    case invite(flags: InviteFlags, title: String, about: String?, photoRepresentation: TelegramMediaImageRepresentation?, participantsCount: Int32, participants: [Peer]?)
    case alreadyJoined(PeerId)
    case invalidHash
    case peek(PeerId, Int32)
}

func _internal_joinChatInteractively(with hash: String, account: Account) -> Signal <PeerId?, JoinLinkError> {
    return account.network.request(Api.functions.messages.importChatInvite(hash: hash))
    |> mapError { error -> JoinLinkError in
        switch error.errorDescription {
            case "CHANNELS_TOO_MUCH":
                return .tooMuchJoined
            case "USERS_TOO_MUCH":
                return .tooMuchUsers
            default:
                return .generic
        }
    }
    |> mapToSignal { updates -> Signal<PeerId?, JoinLinkError> in
        account.stateManager.addUpdates(updates)
        if let peerId = apiUpdatesGroups(updates).first?.peerId {
            return account.postbox.multiplePeersView([peerId])
            |> castError(JoinLinkError.self)
            |> filter { view in
                return view.peers[peerId] != nil
            }
            |> take(1)
            |> map { _ in
                return peerId
            }
            |> timeout(5.0, queue: Queue.concurrentDefaultQueue(), alternate: .single(nil) |> castError(JoinLinkError.self))
        }
        return .single(nil)
    }
}

func _internal_joinLinkInformation(_ hash: String, account: Account) -> Signal<ExternalJoiningChatState, NoError> {
    return account.network.request(Api.functions.messages.checkChatInvite(hash: hash))
    |> map(Optional.init)
    |> `catch` { _ -> Signal<Api.ChatInvite?, NoError> in
        return .single(nil)
    }
    |> mapToSignal { (result) -> Signal<ExternalJoiningChatState, NoError> in
        if let result = result {
            switch result {
                case let .chatInvite(flags, title, about, invitePhoto, participantsCount, participants):
                    let photo = telegramMediaImageFromApiPhoto(invitePhoto).flatMap({ smallestImageRepresentation($0.representations) })
                    let flags:ExternalJoiningChatState.InviteFlags = .init(isChannel: (flags & (1 << 0)) != 0, isBroadcast: (flags & (1 << 1)) != 0, isPublic: (flags & (1 << 2)) != 0, isMegagroup: (flags & (1 << 3)) != 0, requestNeeded: (flags & (1 << 6)) != 0)
                    return .single(.invite(flags: flags, title: title, about: about, photoRepresentation: photo, participantsCount: participantsCount, participants: participants?.map({TelegramUser(user: $0)})))
                case let .chatInviteAlready(chat):
                    if let peer = parseTelegramGroupOrChannel(chat: chat) {
                        return account.postbox.transaction({ (transaction) -> ExternalJoiningChatState in
                            updatePeers(transaction: transaction, peers: [peer], update: { (previous, updated) -> Peer? in
                                return updated
                            })
                            
                            return .alreadyJoined(peer.id)
                        })
                    }
                    return .single(.invalidHash)
                case let .chatInvitePeek(chat, expires):
                    if let peer = parseTelegramGroupOrChannel(chat: chat) {
                        return account.postbox.transaction({ (transaction) -> ExternalJoiningChatState in
                            updatePeers(transaction: transaction, peers: [peer], update: { (previous, updated) -> Peer? in
                                return updated
                            })
                            
                            return .peek(peer.id, expires)
                        })
                    }
                    return .single(.invalidHash)
            }
        } else {
            return .single(.invalidHash)
        }
    }
}
