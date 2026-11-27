Native iOS rewrite of the Expo app at ../speakfcofflineandroid (read-only reference; never edit it).
Port behaviour from its src/ and docs/ folders. Swift 6, SwiftUI, iOS 17+.
Xcode project: PracticeOffline.xcodeproj, scheme PracticeOffline, bundle ID com.tranminhluan.practiceoffline.
Use Apple frameworks first: URLSession, AVFoundation, SwiftData, FileManager, UserNotifications.
Only third-party packages: clerk-ios, firebase-ios-sdk (FirebaseMessaging). Add via Swift Package Manager.
Secrets go in Secrets.xcconfig (gitignored), never in Swift files.
After every change: build with xcodebuild for the iOS Simulator and fix all errors before saying done.
Work one milestone at a time; tell me exactly what to tap to test it.
The user is not a programmer: explain in plain words, and say clearly when they must do something in Xcode or a dashboard themselves.
