import AppKit

/// The app's menu bar. It's visible only while LCX Mixer is in the Dock (the mixer window is open,
/// or "Always in Dock" is on), but its keyboard shortcuts work in every window either way. Without
/// an Edit menu, ⌘C, ⌘V and the other editing shortcuts have nothing to call, and text fields
/// only beep.
@MainActor
enum MainMenu {
    /// `target` handles the two app-specific items, `showAbout(_:)` and `showSettings(_:)`.
    /// Everything else goes to the first responder, the way standard Mac menus do.
    static func install(target: AnyObject, about: Selector, settings: Selector) {
        let main = NSMenu()

        let app = NSMenu(title: "LCX Mixer")
        app.addItem(item("About LCX Mixer", about, target: target))
        app.addItem(.separator())
        app.addItem(item("Settings…", settings, key: ",", target: target))
        app.addItem(.separator())
        app.addItem(item("Hide LCX Mixer", #selector(NSApplication.hide(_:)), key: "h"))
        let hideOthers = item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(hideOthers)
        app.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        app.addItem(.separator())
        app.addItem(item("Quit LCX Mixer", #selector(NSApplication.terminate(_:)), key: "q"))
        main.addItem(submenu(app))

        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), key: "z"))
        let redo = item("Redo", Selector(("redo:")), key: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), key: "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), key: "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), key: "v"))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), key: "a"))
        main.addItem(submenu(edit))

        let window = NSMenu(title: "Window")
        window.addItem(item("Close", #selector(NSWindow.performClose(_:)), key: "w"))
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        main.addItem(submenu(window))

        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }

    private static func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
