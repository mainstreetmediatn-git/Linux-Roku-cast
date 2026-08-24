# Linux-Roku-cast

Roku SceneGraph receiver reconstructed from the uploaded Linux-to-Roku casting design PDF.

## Implemented

- SceneGraph application bootstrap (`source/main.brs`)
- `MainScene`
- `CastVideoPlayer` stream URL and format validation
- ContentNode creation and assignment
- Prebuffer -> prebufferDone -> play state machine
- Authoritative Roku playback-state tracking
- Buffer/underrun/startup diagnostics
- Detailed playback error capture
- Bounded recovery with a maximum of 3 attempts
- Safe stop -> stopped -> prebuffer recovery sequencing

The design document marks Milestones 4A-4D as locked and specifies Milestone 4F as the next physical-device validation step using a known-good MP4 over HTTP.

## Current boundary

The PDF references Milestone 3 (Task & Server Layer) as already locked, but does not contain the complete Milestone 3 source in the supplied pages. This repository therefore contains the receiver/player implementation and runnable SceneGraph scaffold, but the Linux-to-Roku command/socket integration still needs to be restored or implemented before full desktop casting is end-to-end.

## Physical Roku test

Sideload the channel on a Roku developer device, then set `streamFormat` and `streamUrl` on the `CastVideoPlayer` from a test harness or the future server/task layer. Use a Roku-reachable HTTP URL containing a known-good MP4 for Milestone 4F validation.
