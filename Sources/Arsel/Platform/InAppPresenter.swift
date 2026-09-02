#if canImport(UIKit)
import Foundation
import UIKit
import WebKit

/// Draws an in-app message over whatever the app is currently showing.
///
/// This file is the reason the Linux CI job exists: it is the only place UIKit may appear, and
/// `Core/` is proven Foundation-only by that job compiling without it.
///
/// The message is presented in its own `UIWindow` rather than pushed into the host's view
/// hierarchy. A window can be torn down without knowing anything about the host's navigation, it
/// survives a controller being swapped underneath it, and it never mutates a view the host owns —
/// which is the class of breakage nobody ever traces back to an SDK.
final class InAppPresenter {
    private weak var core: ArselCore?
    private var window: UIWindow?
    private var shownAtMs: Int64 = 0
    private var current: InAppMessage?

    init(core: ArselCore) {
        self.core = core
    }

    /// Entry point from the core, which runs on its own serial queue.
    ///
    /// Everything below this line is main-queue only — UIKit demands it, and the hop is explicit
    /// rather than an actor annotation because `MainActor.assumeIsolated` needs iOS 17 and this
    /// package ships to 15.
    func present(_ message: InAppMessage) {
        let delay = max(0, message.delaySeconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay)) { [weak self] in
            self?.show(message)
        }
    }

    private func show(_ message: InAppMessage) {
        // Already showing something, or the app left the foreground during the delay window.
        // Abandoned silently: no beacon and no counter, because a message nobody saw is not an
        // impression and recording one corrupts every rate in the channel.
        guard window == nil, let scene = Self.activeScene() else {
            core?.releaseInAppSlot()
            return
        }

        let host = UIWindow(windowScene: scene)
        host.windowLevel = .alert + 1
        host.backgroundColor = .clear
        let controller = InAppViewController(
            message: message,
            onButton: { [weak self] button in self?.handle(button, for: message) },
            onSubmit: { [weak self] answers in
                self?.core?.recordInAppSubmit(message, submission: answers)
            },
            // A custom-HTML message recording an event of its own. It goes through the same
            // `track` the host app calls, so it is subject to the same opt-out and the same
            // queue — a sandboxed page gets no shortcut into the pipeline.
            onCustomEvent: { [weak self] name in self?.core?.track(name) },
            onDismiss: { [weak self] in self?.close(reportDismiss: true) })
        host.rootViewController = controller
        host.isHidden = false

        window = host
        current = message
        shownAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        // Reported once the view is actually on screen, never at build time.
        core?.recordInAppImpression(message, triggerEventName: message.triggerEventName)
    }

    private func handle(_ button: InAppButton, for message: InAppMessage) {
        if button.action != InAppAction.dismiss {
            // Enqueued BEFORE any navigation: a deep link can background the app immediately, and
            // the queue is on disk so the click survives it.
            core?.recordInAppClick(message, buttonId: button.buttonId)
        }
        close(reportDismiss: button.action == InAppAction.dismiss)

        guard let value = button.value, !value.isEmpty else { return }
        switch button.action {
        case InAppAction.deepLink, InAppAction.url:
            guard let url = URL(string: value) else { return }
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        case InAppAction.customEvent:
            core?.track(value)
        default:
            break
        }
    }

    private func close(reportDismiss: Bool) {
        guard let message = current else { return }
        window?.isHidden = true
        window = nil
        current = nil
        core?.releaseInAppSlot()
        if reportDismiss {
            let visible = Int64(Date().timeIntervalSince1970 * 1000) - shownAtMs
            core?.recordInAppDismiss(message, visibleSeconds: visible / 1000)
        }
    }

    /// The scene actually in front of the user. `.foregroundActive` and not merely connected: a
    /// backgrounded or inactive scene would take the window and show it to nobody.
    private static func activeScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }
}

/// One input's identity and how to read it. Empty means unanswered, whatever the control.
private struct FieldReader {
    let fieldId: String
    let required: Bool
    let read: () -> String
}

/// The message itself. Built in code rather than from a xib, so the package ships no resource
/// bundle for an integrator to carry.
private final class InAppViewController: UIViewController {
    private let message: InAppMessage
    private let onButton: (InAppButton) -> Void
    private let onSubmit: ([String: String]) -> Void
    private let onCustomEvent: (String) -> Void
    private let onDismiss: () -> Void

    /// One entry per input, in the order they were drawn. Populated while building the panel.
    private var readers: [FieldReader] = []

    /// Retained for the life of the message: the web view is owned by the sandbox, not by the
    /// view hierarchy, and dropping it here would tear down the bridge mid-message.
    private var sandbox: InAppWebSandbox?
    private var sandboxHeight: NSLayoutConstraint?

    init(
        message: InAppMessage,
        onButton: @escaping (InAppButton) -> Void,
        onSubmit: @escaping ([String: String]) -> Void,
        onCustomEvent: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.message = message
        self.onButton = onButton
        self.onSubmit = onSubmit
        self.onCustomEvent = onCustomEvent
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used — this controller is never in a storyboard")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        var scrimmed = InAppLayout.scrimmed.contains(message.layout)
        // TRANSPARENT means the app behind stays fully visible, because the author is drawing
        // their own backdrop inside the markup.
        if customHtml?.overlayStyle == InAppOverlayStyle.transparent { scrimmed = false }
        view.backgroundColor = scrimmed ? UIColor.black.withAlphaComponent(Self.scrimAlpha) : UIColor.clear

        let panel = buildPanel()
        view.addSubview(panel)
        constrain(panel)

        // Dismissable by the scrim only when the author allowed a close affordance; otherwise a
        // stray tap destroys a message they meant to be deliberate.
        if scrimmed && message.showCloseButton {
            let tap = UITapGestureRecognizer(target: self, action: #selector(scrimTapped))
            view.addGestureRecognizer(tap)
        }
    }

    @objc private func scrimTapped() {
        onDismiss()
    }

    @objc private func closeTapped() {
        onDismiss()
    }

    @objc private func buttonTapped(_ sender: UIButton) {
        guard sender.tag >= 0, sender.tag < message.buttons.count else { return }
        let button = message.buttons[sender.tag]

        // A form's non-dismiss button submits. Answers are read before the controller tears the
        // view down, and a failed validation aborts the tap entirely so the message stays open
        // with the problem visible.
        if !readers.isEmpty && button.action != InAppAction.dismiss {
            guard let answers = readAnswers() else { return }
            onSubmit(answers)
        }
        onButton(button)
    }

    /// Non-nil only for a CUSTOM_HTML message that arrived with a usable source.
    private var customHtml: InAppCustomHtml? {
        message.layout == InAppLayout.customHtml ? message.customHtml : nil
    }

    private func buildPanel() -> UIView {
        let panelColor = customHtml == nil
            ? (Self.color(from: message.backgroundColor) ?? .systemBackground)
            : .clear
        let textColor = Self.color(from: message.textColor) ?? Self.contrasting(with: panelColor)

        let panel = UIView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.backgroundColor = panelColor
        panel.layer.cornerRadius = Self.cornerRadius
        panel.accessibilityViewIsModal = InAppLayout.scrimmed.contains(message.layout)

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = Self.spacing

        // The markup owns everything visible, so none of the ordinary content is drawn.
        if let custom = customHtml {
            stack.addArrangedSubview(buildSandbox(custom))
        }

        // ALERT is the OS-alert shape: text and actions only, never an image.
        if customHtml == nil, let imageUrl = message.imageUrl, !imageUrl.isEmpty,
           message.layout != InAppLayout.alert {
            stack.addArrangedSubview(imageView(imageUrl))
        }

        if customHtml == nil, message.layout != InAppLayout.imageOnly {
            stack.addArrangedSubview(label(message.headline, size: Self.headlineSize, weight: .semibold, color: textColor))
            if !message.body.isEmpty {
                stack.addArrangedSubview(label(message.body, size: Self.bodySize, weight: .regular, color: textColor))
            }
        }

        if InAppLayout.inputs.contains(message.layout) && !message.fields.isEmpty {
            stack.addArrangedSubview(fieldStack(textColor: textColor))
        }

        if !message.buttons.isEmpty {
            stack.addArrangedSubview(buttonRow())
        }

        panel.addSubview(stack)
        // Custom markup is drawn edge to edge: padding around someone else's design is a border
        // they did not ask for.
        let padding = customHtml == nil ? Self.padding : 0
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: padding),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -padding),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -padding),
        ])

        if message.showCloseButton {
            let close = closeButton(color: textColor)
            panel.addSubview(close)
            NSLayoutConstraint.activate([
                close.topAnchor.constraint(equalTo: panel.topAnchor),
                close.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
                close.widthAnchor.constraint(equalToConstant: Self.minTapTarget),
                close.heightAnchor.constraint(equalToConstant: Self.minTapTarget),
            ])
        }
        return panel
    }

    private func buildSandbox(_ custom: InAppCustomHtml) -> UIView {
        let sandbox = InAppWebSandbox(custom: custom) { [weak self] payload in
            self?.handleBridge(payload)
        }
        self.sandbox = sandbox

        let height =
            sandbox.webView.heightAnchor.constraint(equalToConstant: Self.defaultSandboxHeight)
        height.isActive = true
        sandboxHeight = height
        return sandbox.webView
    }

    /// Runs what a custom-HTML message asked for.
    ///
    /// Nothing here trusts the payload with more than its own intent. A button is named by id and
    /// resolved against the CAMPAIGN's own buttons, so the markup can ask for an action the author
    /// defined but can never invent a destination — the same rule that keeps `fieldKey` off the
    /// wire for forms.
    private func handleBridge(_ payload: [String: Any]) {
        guard let type = payload["type"] as? String else { return }
        switch type {
        case Self.bridgeDismiss:
            onDismiss()
        case Self.bridgeTrack:
            let name = (payload["event"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            onCustomEvent(String(name.prefix(Self.maxBridgeNameCharacters)))
        case Self.bridgeButton:
            let id = payload["buttonId"] as? String
            guard let button = message.buttons.first(where: { $0.buttonId == id }) else { return }
            onButton(button)
        case Self.bridgeSubmit:
            guard let answers = Self.readBridgeSubmission(payload["submission"]) else { return }
            onSubmit(answers)
        case Self.bridgeResize:
            resizeSandbox(payload["height"])
        default:
            break
        }
    }

    /// Bounded before it reaches the queue. The page is untrusted, so a submission of arbitrary
    /// size or shape is refused here rather than enqueued and rejected a round trip later.
    private static func readBridgeSubmission(_ raw: Any?) -> [String: String]? {
        guard let json = raw as? [String: Any],
              !json.isEmpty,
              json.count <= maxBridgeFields else {
            return nil
        }

        var answers: [String: String] = [:]
        for (key, value) in json {
            guard let answer = value as? String else { return nil }
            guard !key.isEmpty, key.count <= maxBridgeNameCharacters else { return nil }
            answers[key] = String(answer.prefix(maxBridgeValueCharacters))
        }
        return answers
    }

    /// Honours a height the markup asks for, clamped.
    ///
    /// Without it a custom message is stuck at whatever the layout guessed, because the page's own
    /// content height is not readable from here. The clamp is what makes obeying it safe: an
    /// unbounded height is a full-screen overlay the user cannot get past.
    private func resizeSandbox(_ raw: Any?) {
        guard let constraint = sandboxHeight, let requested = raw as? Double else { return }
        let ceiling = view.bounds.height * Self.maxSandboxScreenShare
        constraint.constant = min(max(CGFloat(requested), Self.minSandboxHeight), ceiling)
    }

    private func constrain(_ panel: UIView) {
        let guide = view.safeAreaLayoutGuide
        var constraints: [NSLayoutConstraint] = [
            panel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: Self.margin),
            panel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -Self.margin),
        ]
        switch message.layout {
        case InAppLayout.bannerTop:
            constraints.append(panel.topAnchor.constraint(equalTo: guide.topAnchor, constant: Self.margin))
        case InAppLayout.bannerBottom:
            constraints.append(panel.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -Self.margin))
        case InAppLayout.halfInterstitial:
            // Anchored to the bottom so the app stays visible above it, which is the whole point
            // of a half interstitial.
            constraints.append(panel.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -Self.margin))
            constraints.append(panel.heightAnchor.constraint(lessThanOrEqualTo: guide.heightAnchor, multiplier: Self.halfHeightFraction))
        case InAppLayout.fullscreen:
            constraints.append(panel.topAnchor.constraint(equalTo: guide.topAnchor, constant: Self.margin))
            constraints.append(panel.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -Self.margin))
        default:
            constraints.append(panel.centerYAnchor.constraint(equalTo: guide.centerYAnchor))
        }
        NSLayoutConstraint.activate(constraints)
    }

    /// Text is always assigned as a value, never rendered as markup: the content is org-authored
    /// and displays inside the customer's own app.
    private func label(_ text: String, size: CGFloat, weight: UIFont.Weight, color: UIColor) -> UILabel {
        let view = UILabel()
        view.text = text
        view.textColor = color
        view.font = .systemFont(ofSize: size, weight: weight)
        view.numberOfLines = 0
        return view
    }

    /// An image view that fills in once the data arrives.
    ///
    /// Loaded off the main queue and applied back on it. A failed load removes the view and KEEPS
    /// the message — the headline and buttons still carry it, and a blank rectangle reads as a
    /// product bug in a way that "no image" does not.
    private func imageView(_ urlString: String) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        view.heightAnchor.constraint(lessThanOrEqualToConstant: Self.maxImageHeight).isActive = true
        // Hidden until it has something to draw, so a slow network never leaves a gap the text
        // then jumps past when it fills.
        view.isHidden = true

        guard let url = URL(string: urlString), url.scheme?.lowercased() == "https" else {
            return view
        }

        let task = URLSession.shared.dataTask(with: url) { [weak view] data, _, _ in
            guard let data = data, let image = UIImage(data: data) else {
                DispatchQueue.main.async { view?.removeFromSuperview() }
                return
            }
            DispatchQueue.main.async {
                view?.image = image
                view?.isHidden = false
            }
        }
        task.resume()
        return view
    }

    /// Draws the message's inputs and records how to read each one.
    ///
    /// Answers are keyed by `fieldId`; this SDK never receives a destination, so it cannot send
    /// one. The server resolves each id against the campaign it stored.
    private func fieldStack(textColor: UIColor) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = Self.spacing

        for field in message.fields {
            if field.type != InAppFieldType.checkbox {
                let caption = field.required ? "\(field.label) *" : field.label
                stack.addArrangedSubview(label(caption, size: Self.bodySize, weight: .medium, color: textColor))
            }
            stack.addArrangedSubview(control(for: field, textColor: textColor))
        }
        return stack
    }

    private func control(for field: InAppField, textColor: UIColor) -> UIView {
        switch field.type {
        case InAppFieldType.rating:
            return ratingControl(field)
        case InAppFieldType.checkbox:
            return checkboxControl(field, textColor: textColor)
        case InAppFieldType.dropdown, InAppFieldType.radio:
            return choiceControl(field, textColor: textColor)
        default:
            return textControl(field, textColor: textColor)
        }
    }

    /// A segmented control rather than tappable labels: it is a single-choice control, and the
    /// native widget brings the accessibility behaviour a custom view would have to reimplement.
    private func ratingControl(_ field: InAppField) -> UIView {
        let scale = (field.scale ?? inAppDefaultRatingScale) > 1
            ? (field.scale ?? inAppDefaultRatingScale)
            : inAppDefaultRatingScale
        // Stars up to five, numerals beyond: a ten-star row is unreadable at the width a message
        // gets, and NPS is conventionally numeric anyway.
        let titles = (1...scale).map { scale <= inAppDefaultRatingScale ? "★" : "\($0)" }
        let control = UISegmentedControl(items: titles)
        control.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minTapTarget).isActive = true

        readers.append(FieldReader(fieldId: field.fieldId, required: field.required) { [weak control] in
            guard let index = control?.selectedSegmentIndex, index != UISegmentedControl.noSegment else {
                return ""
            }
            return "\(index + 1)"
        })
        return control
    }

    private func textControl(_ field: InAppField, textColor: UIColor) -> UIView {
        let input = UITextField()
        input.borderStyle = .roundedRect
        input.textColor = textColor
        input.placeholder = field.placeholder
        input.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minTapTarget).isActive = true
        switch field.type {
        case InAppFieldType.email:
            input.keyboardType = .emailAddress
            input.autocapitalizationType = .none
        case InAppFieldType.tel:
            input.keyboardType = .phonePad
        default:
            break
        }

        readers.append(FieldReader(fieldId: field.fieldId, required: field.required) { [weak input] in
            (input?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        })
        return input
    }

    private func checkboxControl(_ field: InAppField, textColor: UIColor) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = Self.spacing
        row.alignment = .center

        let toggle = UISwitch()
        let caption = field.required ? "\(field.label) *" : field.label
        row.addArrangedSubview(toggle)
        row.addArrangedSubview(label(caption, size: Self.bodySize, weight: .regular, color: textColor))

        readers.append(FieldReader(fieldId: field.fieldId, required: field.required) { [weak toggle] in
            // A required checkbox must be on, so an off one reads as empty rather than as
            // "false" — otherwise a consent switch would pass validation while recording a refusal.
            guard let isOn = toggle?.isOn else { return "" }
            if isOn { return "true" }
            return field.required ? "" : "false"
        })
        return row
    }

    /// Dropdown and radio collapse to the same control on iOS: a segmented row of the offered
    /// options, which is the platform-native way to pick one of a short list.
    private func choiceControl(_ field: InAppField, textColor: UIColor) -> UIView {
        let control = UISegmentedControl(items: field.options.map { $0.label })
        control.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minTapTarget).isActive = true

        let values = field.options.map { $0.value }
        readers.append(FieldReader(fieldId: field.fieldId, required: field.required) { [weak control] in
            guard let index = control?.selectedSegmentIndex,
                  index != UISegmentedControl.noSegment,
                  index < values.count else {
                return ""
            }
            return values[index]
        })
        return control
    }

    /// Nil when a required field is unanswered — the caller aborts the tap rather than sending a
    /// partial answer.
    private func readAnswers() -> [String: String]? {
        var answers: [String: String] = [:]
        var missing = false

        for reader in readers {
            let value = reader.read()
            if value.isEmpty {
                if reader.required { missing = true }
                continue
            }
            answers[reader.fieldId] = value
        }
        return missing ? nil : answers
    }

    private func buttonRow() -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = Self.spacing
        for (index, button) in message.buttons.enumerated() {
            let view = UIButton(type: .system)
            view.setTitle(button.label, for: .normal)
            view.tag = index
            view.addTarget(self, action: #selector(buttonTapped(_:)), for: .touchUpInside)
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minTapTarget).isActive = true
            row.addArrangedSubview(view)
        }
        return row
    }

    private func closeButton(color: UIColor) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(Self.closeGlyph, for: .normal)
        button.setTitleColor(color, for: .normal)
        button.accessibilityLabel = Self.closeLabel
        button.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        return button
    }

    private static func color(from hex: String?) -> UIColor? {
        guard var value = hex, value.hasPrefix("#") else { return nil }
        value.removeFirst()
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        return UIColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1)
    }

    /// Supplies the readable half of a colour pair when an author set only the background —
    /// otherwise a white-on-white message reports a healthy impression nobody could read.
    private static func contrasting(with background: UIColor) -> UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard background.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return .label }
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return luminance > 0.6 ? .black : .white
    }

    private static let scrimAlpha: CGFloat = 0.45
    private static let cornerRadius: CGFloat = 12
    private static let padding: CGFloat = 20
    private static let margin: CGFloat = 16
    private static let spacing: CGFloat = 8

    /// Apple's minimum touch target; anything smaller fails an accessibility audit.
    private static let minTapTarget: CGFloat = 44
    private static let maxImageHeight: CGFloat = 220
    /// A half interstitial may take at most this much of the screen.
    private static let halfHeightFraction: CGFloat = 0.6
    private static let headlineSize: CGFloat = 18
    private static let bodySize: CGFloat = 15
    private static let closeGlyph = "\u{00D7}"
    private static let closeLabel = "Close"

    private static let bridgeDismiss = "arsel:dismiss"
    private static let bridgeTrack = "arsel:track"
    private static let bridgeButton = "arsel:button"
    private static let bridgeSubmit = "arsel:submit"
    private static let bridgeResize = "arsel:resize"

    /// Bounds on anything crossing the bridge from untrusted markup.
    private static let maxBridgeFields = 20
    private static let maxBridgeNameCharacters = 64
    private static let maxBridgeValueCharacters = 500
    private static let defaultSandboxHeight: CGFloat = 320
    private static let minSandboxHeight: CGFloat = 80

    /// A message may not grow past this share of the screen, whatever it asks for.
    private static let maxSandboxScreenShare: CGFloat = 0.9
}
#endif
