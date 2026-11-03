// Entry point of the system extension. NetworkExtension creates the provider class that
// Filter-Info.plist names under NEProviderClasses.
// From blackice-poc macos/FilterExtension/main.swift at commit 45a7870.
import Foundation
import NetworkExtension

autoreleasepool {
    NEProvider.startSystemExtensionMode()
}
dispatchMain()
