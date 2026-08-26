' ================================================================
' CastVideoPlayer.brs
' Milestone 4E: deterministic prebuffer completion + watchdog telemetry
' ================================================================
sub init()
    print "[CAST][VIDEO][INIT] Initializing CastVideoPlayer component..."
    m.video = m.top.findNode("streamVideo")
    m.statusLabel = m.top.findNode("statusLabel")
    m.prebufferWatchdog = m.top.findNode("prebufferWatchdog")
    m.failureStreak = 0
    m.totalFailures = 0
    m.lastState = "idle"

    initObserversAndFlags()
    initDiagnosticsAndRecovery()

    if m.video = invalid then
        recordFailure("INIT_VIDEO_NODE_INVALID", false)
        return
    end if

    if m.statusLabel = invalid then
        print "[CAST][VIDEO][WARN] statusLabel node could not be resolved"
    end if

    if m.prebufferWatchdog = invalid then
        print "[CAST][VIDEO][WARN] prebuffer watchdog node could not be resolved"
    else
        m.prebufferWatchdog.ObserveField("fire", "onPrebufferWatchdogFired")
    end if

    m.top.playerState = "idle"
    m.top.playbackPosition = 0.0
    publishDiagnosticSnapshot()
    print "[CAST][VIDEO][INIT] CastVideoPlayer ready and waiting for stream configuration."
end sub

sub onStreamUrlChanged()
    print "[CAST][VIDEO][SOURCE] streamUrl field changed"

    if m.video = invalid then
        recordFailure("VIDEO_NODE_INVALID", false)
        return
    end if

    rawUrl as Dynamic = m.top.streamUrl
    if rawUrl = invalid then
        recordFailure("STREAM_URL_INVALID", false)
        return
    end if

    if Type(rawUrl) <> "String" and Type(rawUrl) <> "roString" then
        recordFailure("STREAM_URL_TYPE_INVALID", false)
        return
    end if

    streamUrl as String = Trim(rawUrl)
    if streamUrl = "" then
        print "[CAST][VIDEO][SOURCE] Empty stream URL ignored"
        return
    end if

    rawFormat as Dynamic = m.top.streamFormat
    if rawFormat = invalid then
        recordFailure("STREAM_FORMAT_INVALID", false)
        return
    end if

    if Type(rawFormat) <> "String" and Type(rawFormat) <> "roString" then
        recordFailure("STREAM_FORMAT_TYPE_INVALID", false)
        return
    end if

    streamFormat as String = normalizeStreamFormat(rawFormat)
    if streamFormat = "" then
        recordFailure("STREAM_FORMAT_UNSUPPORTED", false)
        return
    end if

    content as Object = createVideoContent(streamUrl, streamFormat)
    if content = invalid then
        recordFailure("CREATE_CONTENT_FAILED", false)
        return
    end if

    stopPrebufferWatchdog()
    m.video.content = content
    m.content = content
    m.recoveryCount = 0
    m.top.recoveryCount = 0
    m.recoveryPending = false
    m.wasUnderrun = false
    m.lastBufferPercentage = 0
    m.top.lastBufferPercentage = 0

    print "[CAST][VIDEO][CONFIG] ContentNode successfully built and assigned"
    print "[CAST][VIDEO][CONFIG] URL="; streamUrl
    print "[CAST][VIDEO][CONFIG] Format="; streamFormat

    m.top.playerState = "ready_to_prebuffer"
    publishDiagnosticSnapshot()
    triggerPrebuffer()
end sub

function normalizeStreamFormat(streamFormat as String) as String
    if streamFormat = invalid then return ""

    format as String = LCase(Trim(streamFormat))
    if format = "mp4" or format = "hls" or format = "dash" or format = "ism" or format = "mkv" then
        return format
    end if

    print "[CAST][VIDEO][ERROR] Unsupported streamFormat="; format
    return ""
end function

function createVideoContent(streamUrl as String, streamFormat as String) as Object
    if streamUrl = "" then
        print "[CAST][VIDEO][ERROR] createVideoContent URL empty"
        return invalid
    end if

    if streamFormat = "" then
        print "[CAST][VIDEO][ERROR] createVideoContent format empty"
        return invalid
    end if

    content as Object = CreateObject("roSGNode", "ContentNode")
    if content = invalid then
        print "[CAST][VIDEO][ERROR] ContentNode allocation failed"
        return invalid
    end if

    content.url = streamUrl
    content.streamformat = streamFormat
    content.title = "Linux Desktop Cast"
    return content
end function

' ================================================================
' Playback state machine and observers
' ================================================================
sub initObserversAndFlags()
    m.prebufferPlayIssued = false
    m.observersAttached = false
end sub

sub attachVideoObservers()
    if m.video = invalid then
        recordFailure("VIDEO_NODE_MISSING_FOR_OBSERVERS", false)
        return
    end if

    if m.observersAttached = true then return

    m.video.ObserveField("state", "onVideoStateChanged")
    m.video.ObserveField("bufferingStatus", "onBufferingStatusChanged")
    m.video.ObserveField("position", "onPositionChanged")

    m.observersAttached = true
    print "[CAST][VIDEO][OBSERVE] observers attached successfully"
end sub

sub triggerPrebuffer()
    if m.video = invalid then
        recordFailure("VIDEO_NODE_MISSING_FOR_PREBUFFER", false)
        return
    end if

    m.prebufferPlayIssued = false
    m.lastBufferPercentage = 0
    m.top.lastBufferPercentage = 0
    attachVideoObservers()

    print "[CAST][VIDEO] Initiating background prebuffer..."
    m.top.playerState = "prebuffering"

    if m.statusLabel <> invalid then
        m.statusLabel.text = "Prebuffering stream... 0%"
        m.statusLabel.visible = true
    end if

    publishDiagnosticSnapshot()
    startPrebufferWatchdog()
    m.video.control = "prebuffer"
end sub

sub onBufferingStatusChanged()
    if m.video = invalid then
        recordFailure("BUFFER_STATUS_VIDEO_INVALID", false)
        return
    end if

    buffStatus as Dynamic = m.video.bufferingStatus

    ' Roku documents bufferingStatus becoming invalid when buffering is complete.
    ' Treat that transition as authoritative completion if play has not already
    ' been issued. This prevents a permanent prebuffer screen when the final
    ' prebufferDone=true associative-array update is coalesced or missed.
    if buffStatus = invalid then
        print "[CAST][VIDEO][BUFFER] bufferingStatus invalid: buffering complete"
        if m.top.playerState = "prebuffering" and m.prebufferPlayIssued <> true then
            m.prebufferPlayIssued = true
            print "[CAST][VIDEO][BUFFER] completion inferred from invalid bufferingStatus"
            startPlayback()
        end if
        return
    end if

    if Type(buffStatus) <> "roAssociativeArray" then
        print "[CAST][VIDEO][BUFFER][WARN] unexpected type="; Type(buffStatus)
        return
    end if

    m.bufferStatusUpdateCount = m.bufferStatusUpdateCount + 1
    m.top.bufferStatusUpdateCount = m.bufferStatusUpdateCount

    if buffStatus.DoesExist("percentage") then
        m.lastBufferPercentage = buffStatus.percentage
        m.top.lastBufferPercentage = m.lastBufferPercentage
        print "[CAST][VIDEO][BUFFER] percent="; m.lastBufferPercentage
        if m.statusLabel <> invalid then
            m.statusLabel.text = "Prebuffering stream... " + m.lastBufferPercentage.ToStr() + "%"
        end if
    end if

    currentUnderrun as Boolean = false
    if buffStatus.DoesExist("isUnderrun") then
        currentUnderrun = buffStatus.isUnderrun
        print "[CAST][VIDEO][BUFFER] underrun="; currentUnderrun
    end if

    if currentUnderrun = true and m.wasUnderrun = false then
        m.underrunCount = m.underrunCount + 1
        m.top.underrunCount = m.underrunCount
        print "[CAST][VIDEO][METRIC] underrunCount="; m.underrunCount
    end if
    m.wasUnderrun = currentUnderrun

    if buffStatus.DoesExist("prebufferDone") then
        if buffStatus.prebufferDone = true and m.prebufferPlayIssued <> true then
            m.prebufferPlayIssued = true
            print "[CAST][VIDEO][BUFFER] prebuffer complete"
            startPlayback()
            return
        end if
    end if

    publishDiagnosticSnapshot()
end sub

sub startPlayback()
    if m.video = invalid then
        recordFailure("VIDEO_NODE_MISSING_FOR_PLAY", false)
        return
    end if

    stopPrebufferWatchdog()
    print "[CAST][VIDEO][PLAY] issuing play command"
    m.top.playerState = "play_requested"
    publishDiagnosticSnapshot()
    m.video.control = "play"
end sub

sub onVideoStateChanged()
    if m.video = invalid then
        recordFailure("STATE_VIDEO_NODE_INVALID", false)
        return
    end if

    currentState as String = m.video.state
    m.lastState = currentState
    print "[CAST][VIDEO][STATE] "; currentState

    if currentState = "playing" then
        stopPrebufferWatchdog()
        m.top.playerState = "playing"
        m.failureStreak = 0
        m.recoveryPending = false
        m.top.startupTime = m.video.timeToStartStreaming
        if m.statusLabel <> invalid then m.statusLabel.visible = false
        print "[CAST][VIDEO][METRIC] startupSeconds="; m.top.startupTime

    else if currentState = "buffering" then
        m.top.playerState = "buffering"

    else if currentState = "paused" then
        m.top.playerState = "paused"

    else if currentState = "stopping" then
        m.top.playerState = "recovery_stopping"

    else if currentState = "stopped" then
        m.top.playerState = "stopped"
        if m.recoveryPending = true then
            m.recoveryPending = false
            m.prebufferPlayIssued = false
            print "[CAST][VIDEO][RECOVERY] stop complete, restarting prebuffer"
            triggerPrebuffer()
            return
        end if

    else if currentState = "finished" then
        stopPrebufferWatchdog()
        m.top.playerState = "finished"

    else if currentState = "error" then
        stopPrebufferWatchdog()
        handlePlaybackError()
        return
    end if

    publishDiagnosticSnapshot()
end sub

sub handlePlaybackError()
    if m.video = invalid then
        recordFailure("ERROR_VIDEO_NODE_INVALID", false)
        return
    end if

    errCode as Integer = m.video.errorCode
    errMessage as String = m.video.errorMsg
    errStr as String = m.video.errorStr
    errInfo as Dynamic = m.video.errorInfo

    print "[CAST][VIDEO][ERROR] code="; errCode
    print "[CAST][VIDEO][ERROR] msg="; errMessage
    print "[CAST][VIDEO][ERROR] diagnostic="; errStr
    if errInfo <> invalid then print "[CAST][VIDEO][ERROR] errorInfo="; FormatJson(errInfo)

    detailedError as String = "Code " + errCode.ToStr() + ": " + errMessage + " | " + errStr
    m.top.lastError = detailedError
    m.top.playerState = "error"

    if m.statusLabel <> invalid then
        m.statusLabel.text = "Playback Error: " + detailedError
        m.statusLabel.visible = true
    end if

    classification as String = classifyPlaybackError(errInfo, errCode)
    print "[CAST][VIDEO][ERROR] Classified Error Category="; classification

    recordFailure("VIDEO_PLAYBACK_ERROR", true)
    publishDiagnosticSnapshot()

    if canAttemptRecovery() then
        attemptRecovery()
    else
        m.top.playerState = "recovery_exhausted"
        publishDiagnosticSnapshot()
    end if
end sub

sub onPositionChanged()
    if m.video = invalid then
        print "[CAST][VIDEO][POSITION][WARN] video node invalid"
        return
    end if
    m.top.playbackPosition = m.video.position
end sub

' ================================================================
' Prebuffer watchdog
' ================================================================
sub startPrebufferWatchdog()
    if m.prebufferWatchdog = invalid then return
    m.prebufferWatchdog.control = "stop"
    m.prebufferWatchdog.control = "start"
end sub

sub stopPrebufferWatchdog()
    if m.prebufferWatchdog = invalid then return
    m.prebufferWatchdog.control = "stop"
end sub

sub onPrebufferWatchdogFired()
    if m.top.playerState <> "prebuffering" then return
    if m.prebufferPlayIssued = true then return

    m.prebufferTimeoutCount = m.prebufferTimeoutCount + 1
    m.top.prebufferTimeoutCount = m.prebufferTimeoutCount

    print "[CAST][VIDEO][WATCHDOG] prebuffer timeout percent="; m.lastBufferPercentage

    ' Known Roku behavior can occasionally stall at ~99% even though the
    ' decoder has enough media to start. A single guarded play attempt is safer
    ' than leaving the receiver permanently stuck on the prebuffer screen.
    if m.lastBufferPercentage >= 95 then
        m.prebufferPlayIssued = true
        print "[CAST][VIDEO][WATCHDOG] high-water fallback: issuing play"
        startPlayback()
        return
    end if

    reason as String = "PREBUFFER_STALLED_" + m.lastBufferPercentage.ToStr() + "_PERCENT"
    recordFailure(reason, false)
    publishDiagnosticSnapshot()

    if canAttemptRecovery() then
        attemptRecovery()
    else
        m.top.playerState = "recovery_exhausted"
        publishDiagnosticSnapshot()
    end if
end sub

sub recordFailure(failureReason as String, preserveLastError as Boolean)
    m.failureStreak = m.failureStreak + 1
    m.totalFailures = m.totalFailures + 1
    m.top.failureCount = m.totalFailures
    m.top.playerState = "error"

    if preserveLastError = false then m.top.lastError = failureReason

    if m.statusLabel <> invalid then
        if preserveLastError = false then m.statusLabel.text = "Error: " + failureReason
        m.statusLabel.visible = true
    end if

    print "[CAST][FAILURE] reason="; failureReason
    print "[CAST][FAILURE] streak="; m.failureStreak
    print "[CAST][FAILURE] total="; m.totalFailures
end sub

' ================================================================
' Diagnostics, metrics, bounded recovery
' ================================================================
sub initDiagnosticsAndRecovery()
    m.underrunCount = 0
    m.bufferStatusUpdateCount = 0
    m.recoveryCount = 0
    m.maxRecoveries = 3
    m.recoveryPending = false
    m.wasUnderrun = false
    m.lastBufferPercentage = 0
    m.prebufferTimeoutCount = 0
end sub

function classifyPlaybackError(errorInfo as Dynamic, errorCode as Integer) as String
    if errorInfo = invalid or Type(errorInfo) <> "roAssociativeArray" then return "UNKNOWN_ERROR"
    if errorInfo.DoesExist("category") = false then return "UNKNOWN_ERROR"

    category as String = LCase(errorInfo.category)
    if category = "http" then
        return "HTTP_ERROR"
    else if category = "drm" then
        return "DRM_ERROR"
    else if category = "mediaerror" then
        return "MEDIA_ERROR"
    else if category = "mediaplayer" then
        return "PLAYER_ERROR"
    end if

    return "UNKNOWN_ERROR"
end function

sub publishDiagnosticSnapshot()
    snapshot as Object = {
        state: m.top.playerState
        failures: m.totalFailures
        failureStreak: m.failureStreak
        underruns: m.underrunCount
        bufferStatusUpdates: m.bufferStatusUpdateCount
        lastBufferPercentage: m.lastBufferPercentage
        prebufferTimeouts: m.prebufferTimeoutCount
        startupTime: m.top.startupTime
        recoveryCount: m.recoveryCount
        lastError: m.top.lastError
    }
    m.top.diagnosticState = snapshot
end sub

function canAttemptRecovery() as Boolean
    if m.recoveryCount >= m.maxRecoveries then return false
    return true
end function

sub attemptRecovery()
    stopPrebufferWatchdog()

    if canAttemptRecovery() = false then
        print "[CAST][VIDEO][RECOVERY] Circuit open. Max automatic recoveries reached."
        m.top.playerState = "recovery_exhausted"
        if m.statusLabel <> invalid then
            m.statusLabel.text = "Fatal: Recovery Exhausted"
            m.statusLabel.visible = true
        end if
        publishDiagnosticSnapshot()
        return
    end if

    if m.video = invalid then
        recordFailure("RECOVERY_VIDEO_NODE_INVALID", false)
        return
    end if

    m.recoveryCount = m.recoveryCount + 1
    m.top.recoveryCount = m.recoveryCount
    m.recoveryPending = true

    print "[CAST][VIDEO][RECOVERY] attempt="; m.recoveryCount
    publishDiagnosticSnapshot()

    ' Wait for the authoritative stopped state before restarting prebuffer.
    m.video.control = "stop"
end sub
