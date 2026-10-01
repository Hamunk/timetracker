// ttpause: ask macOS to pause whatever is Now Playing, and nothing else.
//
// The one player pause-media.sh could not reach was the lecture video Canvas
// embeds: a player inside an iframe inside another origin's iframe, out of
// reach of any script the browser will run for us. F8 reaches it, because F8
// goes to the Now Playing service and the service tells the browser, which
// tells the player. A synthesised F8 does not (pause-media.sh records seven
// ways that were tried); the service ignores events that did not come from
// the keyboard. This does not send a key. It asks the service directly, with
// MediaRemote's own command, which is how the system's Now Playing controls
// do it.
//
// Two rules from pause-media.sh hold here too. It is a pause and never a
// toggle — kMRPause, not kMRTogglePlayPause — so it cannot start anything that
// was not playing. And it never fails out loud: MediaRemote is a private
// framework, newer macOS versions have narrowed what an ordinary process may
// ask of it, and if the symbol is gone or the request is refused, nothing
// happens, which is exactly what happened before this existed.

import Foundation

typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool
let kMRPause: UInt32 = 1

guard let lib = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
                       RTLD_NOW),
      let sym = dlsym(lib, "MRMediaRemoteSendCommand") else { exit(0) }
let send = unsafeBitCast(sym, to: SendCommand.self)
_ = send(kMRPause, nil)
// The command leaves over XPC; a process that exits at once can take it
// with it. A moment of run loop lets it go.
RunLoop.main.run(until: Date().addingTimeInterval(0.4))
exit(0)
