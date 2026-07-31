import Flutter
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var externalLibraryAccess: ExternalLibraryAccess?
  private var deviceIdentityBridge: DeviceIdentityBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    externalLibraryAccess = ExternalLibraryAccess(
      messenger: engineBridge.applicationRegistrar.messenger()
    )
    deviceIdentityBridge = DeviceIdentityBridge(
      messenger: engineBridge.applicationRegistrar.messenger()
    )
  }
}

private final class DeviceIdentityBridge {
  private static let channelName =
    "com.othbradar.copymangareader/device_identity"
  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "getDeviceIdentity" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let device = UIDevice.current
      guard let platformID = device.identifierForVendor?.uuidString else {
        result(
          FlutterError(
            code: "NO_DEVICE_ID",
            message: "无法取得设备标识",
            details: nil
          )
        )
        return
      }
      result([
        "device": device.model,
        "deviceInfo": "iOS",
        "platformId": platformID,
      ])
    }
  }
}

private final class ExternalLibraryAccess:
  NSObject,
  UIDocumentPickerDelegate,
  UIAdaptivePresentationControllerDelegate
{
  private static let channelName =
    "com.othbradar.copymangareader/external_library"
  private static let bookmarkKey = "external_library_directory_bookmark"

  private let channel: FlutterMethodChannel
  private var pendingResult: FlutterResult?
  private var documentPickerController: UIDocumentPickerViewController?
  private var activeURL: URL?
  private var activeAccessStarted = false
  private var isCompletingSelection = false

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: messenger
    )
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      DispatchQueue.main.async {
        self?.handle(call, result: result)
      }
    }
  }

  deinit {
    stopActiveAccess()
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "pickLibraryDirectory":
      presentDirectoryPicker(result: result)
    case "restoreLibraryDirectoryAccess":
      restoreDirectory(result: result)
    case "releaseLibraryDirectoryAccess":
      releaseDirectory()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func presentDirectoryPicker(result: @escaping FlutterResult) {
    guard pendingResult == nil else {
      result(
        FlutterError(
          code: "PICKER_BUSY",
          message: "目录选择器已打开",
          details: nil
        )
      )
      return
    }
    guard let presenter = Self.topViewController() else {
      result(
        FlutterError(
          code: "NO_VIEW_CONTROLLER",
          message: "无法打开目录选择器",
          details: nil
        )
      )
      return
    }

    pendingResult = result
    let picker: UIDocumentPickerViewController
    if #available(iOS 14.0, *) {
      picker = UIDocumentPickerViewController(
        forOpeningContentTypes: [.folder],
        asCopy: false
      )
    } else {
      picker = UIDocumentPickerViewController(
        documentTypes: ["public.folder"],
        in: .open
      )
    }
    documentPickerController = picker
    picker.delegate = self
    picker.allowsMultipleSelection = false
    picker.presentationController?.delegate = self
    presenter.present(picker, animated: true)
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    guard let url = urls.first else {
      documentPickerController = nil
      complete(nil)
      controller.dismiss(animated: true)
      return
    }

    // The external-volume file provider may already be dismissing the picker
    // when this delegate method is called. Waiting for another dismiss
    // completion can therefore stall forever on a physical iPad. Claim the
    // security scope and return the selection immediately; dismissal and
    // bookmark persistence must not gate the Flutter result.
    isCompletingSelection = true
    documentPickerController = nil
    prepareSelectedDirectory(url)
    controller.dismiss(animated: true)
    isCompletingSelection = false
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    documentPickerController = nil
    complete(nil)
    controller.dismiss(animated: true)
  }

  func presentationControllerDidDismiss(
    _ presentationController: UIPresentationController
  ) {
    documentPickerController = nil
    if !isCompletingSelection && pendingResult != nil {
      complete(nil)
    }
  }

  private func prepareSelectedDirectory(_ url: URL) {
    let started = url.startAccessingSecurityScopedResource()
    guard FileManager.default.fileExists(atPath: url.path) else {
      if started {
        url.stopAccessingSecurityScopedResource()
      }
      complete(
        FlutterError(
          code: "DIRECTORY_ACCESS_FAILED",
          message: "所选目录当前不可访问",
          details: nil
        )
      )
      return
    }

    stopActiveAccess()
    activeURL = url
    activeAccessStarted = started
    complete(url.path)

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      do {
        let bookmark = try url.bookmarkData(
          options: .minimalBookmark,
          includingResourceValuesForKeys: nil,
          relativeTo: nil
        )
        DispatchQueue.main.async {
          guard let self else {
            if started {
              url.stopAccessingSecurityScopedResource()
            }
            return
          }
          if self.activeURL == url {
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
          }
        }
      } catch {
        DispatchQueue.main.async { [weak self] in
          // Keep the current security scope alive for this process, but avoid
          // restoring a stale bookmark after the next launch.
          self?.clearBookmarkIfActiveURL(url)
        }
      }
    }
  }

  private func clearBookmarkIfActiveURL(_ url: URL) {
    if activeURL == url {
      UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
    }
  }

  private func restoreDirectory(result: @escaping FlutterResult) {
    guard
      let bookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey)
    else {
      result(nil)
      return
    }
    do {
      var stale = false
      let url = try URL(
        resolvingBookmarkData: bookmark,
        options: [.withoutUI],
        relativeTo: nil,
        bookmarkDataIsStale: &stale
      )
      let started = url.startAccessingSecurityScopedResource()
      guard FileManager.default.fileExists(atPath: url.path) else {
        if started {
          url.stopAccessingSecurityScopedResource()
        }
        result(nil)
        return
      }
      if stale {
        let refreshed = try url.bookmarkData(
          options: .minimalBookmark,
          includingResourceValuesForKeys: nil,
          relativeTo: nil
        )
        UserDefaults.standard.set(refreshed, forKey: Self.bookmarkKey)
      }
      stopActiveAccess()
      activeURL = url
      activeAccessStarted = started
      result(url.path)
    } catch {
      result(nil)
    }
  }

  private func releaseDirectory() {
    stopActiveAccess()
    UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
  }

  private func stopActiveAccess() {
    if activeAccessStarted {
      activeURL?.stopAccessingSecurityScopedResource()
    }
    activeURL = nil
    activeAccessStarted = false
  }

  private func complete(_ value: Any?) {
    pendingResult?(value)
    pendingResult = nil
  }

  private static func topViewController() -> UIViewController? {
    let root = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first(where: \.isKeyWindow)?
      .rootViewController
    return visibleController(from: root)
  }

  private static func visibleController(
    from controller: UIViewController?
  ) -> UIViewController? {
    if let presented = controller?.presentedViewController {
      return visibleController(from: presented)
    }
    if let navigation = controller as? UINavigationController {
      return visibleController(from: navigation.visibleViewController)
    }
    if let tabs = controller as? UITabBarController {
      return visibleController(from: tabs.selectedViewController)
    }
    return controller
  }
}
