import AppKit
import Foundation
import CoreGraphics

/// Real `DisplayBrightnessProviding`. The built-in display's Nominal range
/// (0–100%) is driven via `DisplayServices.framework`'s
/// `DisplayServicesSetBrightness`, which takes the exact `Float` 0.0...1.0
/// value Control Center's own slider reads and writes — no translation
/// needed beyond dividing by 100.
///
/// Extended Brightness / Boost (100–200%) is delegated to `BoostEngagement`
/// (`BoostEngagement.swift`), since there is no reliable private "set
/// brightness past 1.0" symbol on this hardware/OS. Factor 1.0 (the Nominal
/// ceiling) at 100%, and at 200% the ceiling `BoostCalibration` derives from
/// the panel's headroom (2.0, about 1000 nits sustained, on a 500-nit panel).
///
/// Everything here targets the built-in display only. Its id is re-resolved
/// whenever the display configuration changes (lid, hot-plug), and while no
/// built-in display is online brightness control is simply unavailable — it
/// is never redirected to an external monitor.
///
/// `@MainActor`: satisfies `DisplayBrightnessProviding`'s isolation, and its
/// own `NSScreen` lookups and `BoostEngagement` are main-thread-only anyway.
@MainActor
final class LiveDisplayBrightnessProvider: DisplayBrightnessProviding {
    private var displayID: CGDirectDisplayID?
    private let symbols: DisplayServicesSymbols
    private let boostEngagement: BoostEngagement
    private var lastReportedConfiguration: Configuration
    private var screenParametersObserver: NSObjectProtocol?
    private var reconfigurationObserver: DisplayReconfigurationObserver?
    /// Which non-zero `DisplayServicesSetBrightness` results were already
    /// logged, so a refusal repeated on every slider tick logs once.
    private var reportedSetBrightnessFailures = DistinctCodeTracker()
    /// The last Boost verdict per display id, so a momentary loss of the
    /// panel's `NSScreen` does not flip Boost off and back on.
    private var boostVerdict: (displayID: CGDirectDisplayID, supported: Bool)?

    var onDisplayConfigurationChange: (() -> Void)?

    /// What `onDisplayConfigurationChange` is about: a change in either
    /// makes the controller re-evaluate.
    private struct Configuration: Equatable {
        var displayID: CGDirectDisplayID?
        var supportsBoost: Bool
        var isAvailable: Bool
        var nominalControl: NominalControlStatus
    }

    init() {
        let displayID = BuiltInDisplay.resolveID()
        self.displayID = displayID
        self.symbols = DisplayServicesSymbols.load()
        self.boostEngagement = BoostEngagement(displayID: displayID)
        self.lastReportedConfiguration = Configuration(displayID: displayID, supportsBoost: false, isAvailable: false, nominalControl: .available)
        self.lastReportedConfiguration = currentConfiguration(displayID: displayID)
        logHeadroom(displayID: displayID)
        self.screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.displayConfigurationChanged()
            }
        }
        self.reconfigurationObserver = DisplayReconfigurationObserver { [weak self] in
            self?.displayConfigurationChanged()
        }
    }

    isolated deinit {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
    }

    /// The built-in display is online and active. An online but inactive
    /// panel (lid closed) has nothing to drive.
    var isBuiltInDisplayAvailable: Bool {
        guard let displayID else { return false }
        return BuiltInDisplay.isActive(displayID)
    }

    /// Whether Nominal brightness can be set right now: the private symbol
    /// was found, and the system allows the built-in display's brightness to
    /// change (it does not under a reference display preset). Boost does not
    /// depend on it.
    var nominalControl: NominalControlStatus {
        let canChange = displayID.flatMap { id in symbols.canChangeBrightness.map { $0(id) } }
        return NominalControlStatus.resolve(hasSetSymbol: symbols.setBrightness != nil, canChange: canChange)
    }

    func apply(percentage: Double) -> BrightnessApplyOutcome {
        guard let displayID, isBuiltInDisplayAvailable else { return .displayUnavailable }
        applyNominal(percentage: percentage, displayID: displayID)
        return applyBoost(percentage: percentage)
    }

    /// Sets the Nominal level. A missing symbol was already logged at load.
    /// A refusal (a non-zero result, 1000 when the display cannot change
    /// brightness) is logged once per distinct code; success re-arms the
    /// log, so a later refusal is reported again.
    private func applyNominal(percentage: Double, displayID: CGDirectDisplayID) {
        guard let setBrightness = symbols.setBrightness else { return }
        let nominalPercentage = min(max(percentage, 0), BrightnessController.nominalCeilingPercentage)
        let value = Float(nominalPercentage / BrightnessController.nominalCeilingPercentage)
        let result = setBrightness(displayID, value)
        if result == 0 {
            reportedSetBrightnessFailures.reset()
        } else if reportedSetBrightnessFailures.isNew(result) {
            Log.display.error("DisplayServicesSetBrightness failed with result \(result, privacy: .public) for display \(displayID, privacy: .public)")
        }
    }

    /// `nil` when there is no built-in display, the symbol couldn't be
    /// loaded, or the call itself fails (return code != 0). A read-only call
    /// with no side effects, so it's safe to call from `BrightnessController.init`
    /// as well as afterwards to notice a change made outside BrightBoi.
    func currentNominalPercentage() -> Double? {
        guard let displayID, let getBrightness = symbols.getBrightness else { return nil }
        var value: Float = 0
        let result = getBrightness(displayID, &value)
        guard result == 0 else { return nil }
        return Double(value) * BrightnessController.nominalCeilingPercentage
    }

    /// The Boost-only half of adopting a brightness change made outside
    /// BrightBoi: releases the scaled gamma table and EDR headroom without
    /// touching Nominal, since Nominal is already at whatever the outside
    /// change set it to.
    func adoptExternalNominal() {
        boostEngagement.disengage()
    }

    /// Boost is available when the built-in display is online and its panel
    /// could grant enough EDR headroom (`BoostHeadroom.hasBoostHeadroom`).
    /// This reads the panel's *potential* headroom, never the granted one:
    /// the granted value stays at 1.0 until some window asks for EDR, so it
    /// would report an idle XDR MacBook Pro as unable to boost. No
    /// hardcoded Mac-model table.
    func supportsExtendedBrightness() -> Bool {
        supportsBoost(displayID: displayID)
    }

    private func supportsBoost(displayID: CGDirectDisplayID?) -> Bool {
        guard let displayID, BuiltInDisplay.isActive(displayID) else { return false }
        let previous = boostVerdict.flatMap { $0.displayID == displayID ? $0.supported : nil }
        let verdict = BoostHeadroom.boostSupport(
            potential: BoostHeadroom.read(displayID: displayID)?.potential,
            previousVerdict: previous
        )
        boostVerdict = (displayID, verdict)
        return verdict
    }

    private func currentConfiguration(displayID: CGDirectDisplayID?) -> Configuration {
        Configuration(
            displayID: displayID,
            supportsBoost: supportsBoost(displayID: displayID),
            isAvailable: displayID.map(BuiltInDisplay.isActive) ?? false,
            nominalControl: nominalControl
        )
    }

    /// Logged once at launch, so a report of Boost missing (or wrongly
    /// offered) on some Mac shows the number the decision was made on.
    private func logHeadroom(displayID: CGDirectDisplayID?) {
        guard let displayID else {
            Log.display.notice("No built-in display online: brightness control unavailable")
            return
        }
        let potential = BoostHeadroom.read(displayID: displayID)?.potential
        let potentialText = potential.map { "\($0)" } ?? "unreadable (no screen)"
        let verdict = supportsBoost(displayID: displayID) ? "Boost available" : "Boost unavailable"
        Log.display.notice("Built-in display \(displayID, privacy: .public): potential EDR headroom \(potentialText, privacy: .public), Boost needs at least \(BoostHeadroom.minimumPotentialForBoost, privacy: .public): \(verdict, privacy: .public)")
    }

    private func applyBoost(percentage: Double) -> BrightnessApplyOutcome {
        guard percentage > BrightnessController.nominalCeilingPercentage else {
            boostEngagement.disengage()
            return .applied
        }

        let boostRange = BrightnessController.maximumPercentage - BrightnessController.nominalCeilingPercentage
        let boostFraction = min(max(percentage - BrightnessController.nominalCeilingPercentage, 0), boostRange) / boostRange
        return boostEngagement.engage(boostFraction: boostFraction)
    }

    /// Re-resolves the built-in display after the display configuration
    /// changed (lid closed or opened, a display plugged or unplugged, the
    /// arrangement changed). Boost follows first, so an overlay and a scaled
    /// table are never left on a display that is gone; the controller is only
    /// told when its answers to `isBuiltInDisplayAvailable`,
    /// `supportsExtendedBrightness()` or `nominalControl` actually changed.
    private func displayConfigurationChanged() {
        let newID = BuiltInDisplay.resolveID()
        boostEngagement.displayConfigurationChanged(displayID: newID)
        displayID = newID
        let configuration = currentConfiguration(displayID: newID)
        guard configuration != lastReportedConfiguration else { return }
        lastReportedConfiguration = configuration
        onDisplayConfigurationChange?()
    }
}
