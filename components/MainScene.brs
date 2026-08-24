sub init()
    m.player = m.top.findNode("castVideoPlayer")
    if m.player = invalid then
        print "[CAST][SCENE][ERROR] CastVideoPlayer missing"
        return
    end if
    m.player.setFocus(true)
    print "[CAST][SCENE] Receiver ready"
end sub
