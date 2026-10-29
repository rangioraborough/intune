/// Every module the agent knows about, in run order. Modules that depend on others go after them.
public enum ModuleRegistry {
    public static let all: [Module] = [
        // Device
        DeviceNameModule(),
        AdminAccountModule(),
        AppsModule(),            // Rosetta and the printer driver before the queues that need it
        // After apps: Office and OneDrive installs bring back AutoUpdate and updater items.
        MAUModule(),
        LoginItemsModule(),
        WebAppsModule(),
        PrinterQueuesModule(),
        AvatarModule(),
        // Session. Preferences before Dock so a Finder/Dock restart triggered by preferences happens first.
        PreferencesModule(),
        UserLoginItemsModule(),
        DockModule(),
        WallpaperModule(),
        PrinterPresetsModule(),
        BrowserFirstRunModule(),
        DefaultBrowserModule(),  // last: it can wait on the user answering a system dialog
        // Last, so it sees this run's results before removing anything.
        LegacyCleanupModule(),
    ]
}
