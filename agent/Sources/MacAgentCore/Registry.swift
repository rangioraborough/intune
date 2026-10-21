/// Every module the agent knows about, in run order. Modules that depend on others go after them.
public enum ModuleRegistry {
    public static let all: [Module] = [
        DeviceNameModule(),
        // Preferences before Dock so a Finder/Dock restart triggered by preferences happens first.
        PreferencesModule(),
        DockModule(),
        // Last, so it sees this run's results before removing anything.
        LegacyCleanupModule(),
    ]
}
