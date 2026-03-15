## Proof of concept upload server and iOS mobile app.

We are interesting in understanding the performance of uploading large files via an iOS mobile app using the HTTP resumable upload protocol in SwiftNIO as demonstrated in BuildingAResumableUploadServerWithSwiftNIO. More details can be found at https://developer.apple.com/documentation/foundation/building-a-resumable-upload-server-with-swiftnio

To do this, we want to build a prototype ios mobile app and a SwiftNIO upload server that supports this protocol.

### Required characteristics:
- The upload server can be exposed via ngrok so that we can test it without a complex deployment.
- The mobile app should be able to upload large files, up to 5 GB in size.
- The upload should continue even if the app is backgrounded or killed.

### Things we want to test
- the speed of a single upload
- what happens when you lose internet on the phone
- what happens when you switch (cellular to wifi) 
- what happens when backgrounding or killing the app in the middle of an upload
- progress update support
- pause, resume, and cancellation capabilities

### Clarifications

Before building, I have a few clarifying questions:

  ## Server questions:
  1. File storage: Should the server save uploaded files to disk, or just measure throughput (discard data after counting bytes)?
  2. Server structure: Should I create a new Swift package in a subfolder (e.g., UploadServer/) that depends on the BuildingAResumableUploadServerWithSwiftNIO
   library, or build it standalone?

  ## iOS app questions:
  3. File source: Should the app upload files from the photo library (videos), the Files app (arbitrary files), or both?
  4. Minimum iOS version: What's acceptable? (iOS 16+ gives us nice Swift concurrency APIs)
  5. UI scope: How minimal should the UI be? I'm thinking:
  - File picker to select a file
  - Server URL input field (pre-filled with ngrok URL)
  - Upload progress bar
  - Pause / Resume / Cancel buttons
  - Status display (speed, offset, connection state)

     Is that the right scope, or do you want more/less?

  6. Chunk size: Should the chunk size for upload pieces be configurable in the UI, or hard-coded to something like 1 MB?
  7. Background uploads: Should the app support continuing uploads when backgrounded (using URLSession background tasks), or is foreground-only fine for this
  proof of concept?

## Answers to questions. 
❯ 1. Just measure throughput for now. 2. Build it standalone. 3. The app should upload files from the photo library. 4. You can assume iOS 26.0+. 5. That is  
the correct scope. 6. Chunk size should be configurable in the UI. 7. The app must support continuing uploads when backgrounded.   