import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var externalLibraryAccess: MacExternalLibraryAccess?
  private var deviceIdentityBridge: MacDeviceIdentityBridge?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    let messenger = flutterViewController.engine.binaryMessenger
    externalLibraryAccess = MacExternalLibraryAccess(
      messenger: messenger,
      parentWindow: self
    )
    deviceIdentityBridge = MacDeviceIdentityBridge(messenger: messenger)

    title = "拷贝漫画阅读器"
    minSize = NSSize(width: 900, height: 640)
    setContentSize(NSSize(width: 1180, height: 800))
    center()

    super.awakeFromNib()
  }
}

private final class MacExternalLibraryAccess {
  private static let bookmarkKey = "external_library_directory_bookmark_macos"

  private let channel: FlutterMethodChannel
  private weak var parentWindow: NSWindow?
  private var activeURL: URL?
  private var activeAccessStarted = false
  private var pickerVisible = false

  init(messenger: FlutterBinaryMessenger, parentWindow: NSWindow) {
    channel = FlutterMethodChannel(
      name: "com.othbradar.copymangareader/external_library",
      binaryMessenger: messenger
    )
    self.parentWindow = parentWindow
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(
          FlutterError(
            code: "bridge_unavailable",
            message: "macOS 文件访问桥接不可用",
            details: nil
          )
        )
        return
      }
      switch call.method {
      case "pickLibraryDirectory":
        self.pickLibraryDirectory(result: result)
      case "restoreLibraryDirectoryAccess":
        self.restoreLibraryDirectoryAccess(result: result)
      case "releaseLibraryDirectoryAccess":
        self.releaseLibraryDirectoryAccess()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  deinit {
    stopActiveAccess()
  }

  private func pickLibraryDirectory(result: @escaping FlutterResult) {
    guard !pickerVisible else {
      result(
        FlutterError(
          code: "picker_busy",
          message: "文件夹选择器已经打开",
          details: nil
        )
      )
      return
    }
    pickerVisible = true

    let panel = NSOpenPanel()
    panel.title = "选择漫画库文件夹"
    panel.message = "请选择包含“拷贝漫画总索引.db”的漫画库文件夹"
    panel.prompt = "打开"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    panel.resolvesAliases = true

    let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
      guard let self else {
        result(nil)
        return
      }
      self.pickerVisible = false
      guard response == .OK, let selectedURL = panel.url else {
        result(nil)
        return
      }
      do {
        try self.rememberAndActivate(selectedURL)
        result(selectedURL.path)
      } catch {
        result(
          FlutterError(
            code: "bookmark_failed",
            message: "无法保存所选漫画库的长期访问权限",
            details: error.localizedDescription
          )
        )
      }
    }

    if let parentWindow {
      panel.beginSheetModal(for: parentWindow, completionHandler: completion)
    } else {
      completion(panel.runModal())
    }
  }

  private func restoreLibraryDirectoryAccess(result: FlutterResult) {
    guard
      let bookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey)
    else {
      result(nil)
      return
    }

    do {
      var isStale = false
      let url = try URL(
        resolvingBookmarkData: bookmark,
        options: [.withSecurityScope],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
      guard FileManager.default.fileExists(atPath: url.path) else {
        releaseLibraryDirectoryAccess()
        result(nil)
        return
      }
      activate(url)
      if isStale {
        try storeBookmark(for: url)
      }
      result(url.path)
    } catch {
      releaseLibraryDirectoryAccess()
      result(nil)
    }
  }

  private func releaseLibraryDirectoryAccess() {
    stopActiveAccess()
    UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
  }

  private func rememberAndActivate(_ url: URL) throws {
    stopActiveAccess()
    activate(url)
    do {
      try storeBookmark(for: url)
    } catch {
      stopActiveAccess()
      throw error
    }
  }

  private func activate(_ url: URL) {
    stopActiveAccess()
    activeURL = url
    activeAccessStarted = url.startAccessingSecurityScopedResource()
  }

  private func stopActiveAccess() {
    if activeAccessStarted {
      activeURL?.stopAccessingSecurityScopedResource()
    }
    activeAccessStarted = false
    activeURL = nil
  }

  private func storeBookmark(for url: URL) throws {
    let bookmark = try url.bookmarkData(
      options: [.withSecurityScope],
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
    UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
  }
}

private final class MacDeviceIdentityBridge {
  private static let installationIDKey = "copy_manga_reader_installation_id"

  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "com.othbradar.copymangareader/device_identity",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "getDeviceIdentity" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result([
        "device": Host.current().localizedName ?? "Mac",
        "deviceInfo": ProcessInfo.processInfo.operatingSystemVersionString,
        "platformId": Self.installationID(),
      ])
    }
  }

  private static func installationID() -> String {
    let defaults = UserDefaults.standard
    if let saved = defaults.string(forKey: installationIDKey), !saved.isEmpty {
      return saved
    }
    let created = UUID().uuidString.lowercased()
    defaults.set(created, forKey: installationIDKey)
    return created
  }
}
