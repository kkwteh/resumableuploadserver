# Test Results

These are results from testing the mobile app on my iPhone 17 Pro uploading via ngrok to the UploadServer running on my laptop.

- SUCCESS Uploads with app is in the foreground
- SUCCESS Wifi uploads work when the app is initiated in the foreground, and then the app is placed in the background
- SUCCESS Uploads can be paused and resumed in the mobile app successfully.
- SUCCESS Uploads continually report progress to the mobile app.
- SUCCESS Uploads work if I switch from Wifi to cellular and from cellular to wifi.
- SUCCESS Initiate upload in foreground, then move app to background, then turn on airplane mode and turn off airplane mode.
- SUCCESS Wifi uploads work if the phone is in the background, or if the phone is in sleep mode.
- FAIL Cellular connection makes progress while app is in the background.
- Uploads can be cancelled

## Observations

- When app is killed, the upload stops making progress, but when the app is restarted, the upload continues to make progress where it left off. 