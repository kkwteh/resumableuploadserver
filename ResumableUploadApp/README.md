# ResumableUploadApp

Minimal iOS app for background video uploads using `URLSession` file-backed upload tasks. When the backend supports Apple's resumable upload flow based on the current IETF HTTP resumable upload draft, the app can keep uploading while suspended, survive phone sleep, and support manual pause/resume through upload resume data.

## What it does

- Lets the user pick a single video from their photo library.
- Lets the user specify the backend URL and bearer token in the app UI.
- Stages the video into the app sandbox so the file remains available for background transfer and later resume.
- Starts uploads in a fixed-identifier background `URLSession`.
- Persists upload state so the app can reconnect UI state to in-flight tasks after relaunch.
- Supports pause, resume, and cancel from the app UI.
- Uses aggressive background transfer settings:
  - `sessionSendsLaunchEvents = true`
  - `isDiscretionary = false`
  - `allowsCellularAccess = true`
  - `allowsExpensiveNetworkAccess = true`
  - `allowsConstrainedNetworkAccess = true`

## Backend requirements

Apple's resumable upload support is automatic on the client side, but only works if the server speaks the current draft resumable upload protocol that `URLSession` expects.

At the time this app was built:

- The latest draft is `draft-ietf-httpbis-resumable-upload-11`
- The current draft interop version is `8`

The backend should implement the draft flow on the upload endpoint that receives the original request and must support the resumable-upload behaviors that `URLSession` depends on, including:

- `104 Upload Resumption Supported`
- stable upload resource `Location`
- `Upload-Offset`
- draft interop version handling

Useful references:

- [Apple: Pausing and resuming uploads](https://developer.apple.com/documentation/foundation/pausing-and-resuming-uploads)
- [IETF draft: Resumable Uploads for HTTP](https://datatracker.ietf.org/doc/draft-ietf-httpbis-resumable-upload/)

## Project layout

- `ResumableUploadApp/UploadStore.swift`: background upload engine, persistence, pause/resume/cancel
- `ResumableUploadApp/ContentView.swift`: single-screen UI
- `ResumableUploadApp/Support/VideoPicker.swift`: PHPicker bridge for selecting a video
- `ResumableUploadApp/Support/AppDelegate.swift`: background URLSession handoff

## Notes

- Background uploads must be created from files, not in-memory data, to remain eligible for background execution.
- Manual pause uses `cancel(byProducingResumeData:)`. If the server does not support Apple's resumable upload integration, resume data will be `nil` and the app surfaces that explicitly.
- New uploads include `Authorization: Bearer <token>` when the token field is populated.
