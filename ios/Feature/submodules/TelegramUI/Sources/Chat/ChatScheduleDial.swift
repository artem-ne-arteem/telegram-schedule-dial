// Schedule Dial
//
// Long-press Send: a rounded glass dome appears above the send button. The long hand
// picks the hour, the short hand the minutes (5 min steps), the bell on top toggles a
// silent send, and the send button turns into a "schedule" button. The message is
// scheduled through Telegram's own scheduled messages.

import Foundation
import UIKit
import AsyncDisplayKit
import ContextUI
import Display
import SwiftSignalKit
import TelegramCore
import TelegramNotices
import ChatSendMessageActionUI
import AccountContext
import TopMessageReactions
import ReactionSelectionNode
import ChatControllerInteraction
import ChatSendAudioMessageContextPreview

func presentChatScheduleDial(selfController: ChatControllerImpl, sendButton: ASDisplayNode, sendControl: ASControlNode?) {
    guard let window = selfController.view.window else {
        return
    }
    let sendButtonFrame = sendButton.view.convert(sendButton.view.bounds, to: window)
    let theme = selfController.presentationData.theme
    let accentColor = theme.list.itemAccentColor
    let primaryColor = theme.list.itemPrimaryTextColor
    let isDark = theme.overallDarkAppearance

    // Lifting the finger after the long press must not count as a tap on Send.
    sendControl?.isEnabled = false

    let controller = ChatScheduleDialController(makeDial: { bounds in
        return ChatScheduleDialView(frame: bounds, sendButtonFrame: sendButtonFrame, accentColor: accentColor, primaryColor: primaryColor, isDark: isDark)
    }, onSchedule: { [weak selfController] timestamp, silent in
        guard let selfController else {
            return
        }
        selfController.chatDisplayNode.sendCurrentMessage(silentPosting: silent, scheduleTime: timestamp, completion: { [weak selfController] in
            guard let selfController else {
                return
            }
            selfController.updateChatPresentationInterfaceState(animated: true, interactive: false, saveInterfaceState: true, {
                $0.updatedInterfaceState { $0.withUpdatedReplyMessageSubject(nil).withUpdatedSendMessageEffect(nil).withUpdatedPostSuggestionState(nil).withUpdatedForwardMessageIds(nil).withUpdatedForwardOptionsState(nil).withUpdatedComposeInputState(ChatTextInputState(inputText: NSAttributedString(string: ""))) }
            })
        })
    }, onClosed: { [weak sendControl] in
        sendControl?.isEnabled = true
    })
    selfController.present(controller, in: .window(.root))
}

/// Hosts the dial as a regular Telegram overlay, so it receives touches and is
/// dismissed like any other presented controller.
private final class ChatScheduleDialController: ViewController {
    private let makeDial: (CGRect) -> ChatScheduleDialView
    private let onSchedule: (Int32, Bool) -> Void
    private let onClosed: () -> Void
    private var dialView: ChatScheduleDialView?

    init(makeDial: @escaping (CGRect) -> ChatScheduleDialView, onSchedule: @escaping (Int32, Bool) -> Void, onClosed: @escaping () -> Void) {
        self.makeDial = makeDial
        self.onSchedule = onSchedule
        self.onClosed = onClosed
        super.init(navigationBarPresentationData: nil)
        self.statusBar.statusBarStyle = .Ignore
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNodeDidLoad()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)

        if self.dialView == nil {
            let dial = self.makeDial(CGRect(origin: CGPoint(), size: layout.size))
            let onSchedule = self.onSchedule
            dial.onSchedule = { timestamp, silent in
                onSchedule(timestamp, silent)
            }
            let onClosed = self.onClosed
            dial.onClosed = { [weak self] in
                onClosed()
                self?.dismiss(completion: nil)
            }
            self.dialView = dial
            self.displayNode.view.addSubview(dial)
            dial.animateIn()
        }
    }
}

/// A rounded glass dome above the send button: the long hand picks the hour, the short
/// hand the minutes, the bell on top switches between a normal and a silent send.
private final class ChatScheduleDialView: UIView {
    private enum Hand {
        case hour
        case minute
    }

    var onSchedule: ((Int32, Bool) -> Void)?
    var onClosed: (() -> Void)?

    private let accentColor: UIColor
    private let primaryColor: UIColor
    private let sendButtonFrame: CGRect
    private let radius: CGFloat = 150.0
    private let baseHeight: CGFloat = 30.0
    private let hourHandLength: CGFloat = 112.0
    private let minuteHandLength: CGFloat = 76.0
    private let pivot: CGPoint

    private let dimView = UIView()
    private let contentView = UIView()
    private let panelView = UIView()
    private let panelOutline = CAShapeLayer()
    private let ticksLayer = CAShapeLayer()
    private var hourLabels: [UILabel] = []
    private let hourHand = UIView()
    private let minuteHand = UIView()
    private let hubView = UIView()
    private let timeLabel = UILabel()
    private let dayLabel = UILabel()
    private let bellView: UIVisualEffectView
    private let bellButton = UIButton(type: .system)
    private let confirmButton = UIButton(type: .system)
    private let selectionFeedback = UISelectionFeedbackGenerator()

    private var hour: Int
    private var minute: Int
    private var silent = false
    private var activeHand: Hand?
    private var isDismissing = false

    init(frame: CGRect, sendButtonFrame: CGRect, accentColor: UIColor, primaryColor: UIColor, isDark: Bool) {
        self.sendButtonFrame = sendButtonFrame
        self.accentColor = accentColor
        self.primaryColor = primaryColor

        let hubRadius: CGFloat = 38.0
        let pivotX = min(max(sendButtonFrame.midX, 150.0 + 12.0), frame.width - 150.0 - 12.0)
        self.pivot = CGPoint(x: pivotX, y: sendButtonFrame.minY - 16.0 - hubRadius)

        let material: UIBlurEffect.Style = isDark ? .systemChromeMaterialDark : .systemChromeMaterialLight
        var bellIsGlass = false
        if #available(iOS 26.0, *) {
            self.bellView = UIVisualEffectView(effect: UIGlassEffect())
            bellIsGlass = true
        } else {
            self.bellView = UIVisualEffectView(effect: UIBlurEffect(style: material))
        }

        // Start one hour from now, rounded to five minutes.
        let start = Date().addingTimeInterval(3600.0)
        let calendar = Calendar.current
        self.hour = calendar.component(.hour, from: start)
        self.minute = (calendar.component(.minute, from: start) / 5) * 5

        super.init(frame: frame)

        self.dimView.frame = self.bounds
        self.dimView.backgroundColor = UIColor(white: 0.0, alpha: isDark ? 0.4 : 0.2)
        self.dimView.alpha = 0.0
        self.addSubview(self.dimView)

        self.contentView.frame = self.bounds
        self.addSubview(self.contentView)

        // Rounded dome: a half circle with a short base and round lower corners.
        let radius = self.radius
        let panelHeight = radius + self.baseHeight
        self.panelView.frame = CGRect(x: self.pivot.x - radius, y: self.pivot.y - radius, width: radius * 2.0, height: panelHeight)
        let domePath = ChatScheduleDialView.domePath(width: radius * 2.0, height: panelHeight, radius: radius, cornerRadius: self.baseHeight)
        let panelMask = CAShapeLayer()
        panelMask.path = domePath.cgPath
        self.panelView.layer.mask = panelMask
        let panelBlur = UIVisualEffectView(effect: UIBlurEffect(style: material))
        panelBlur.frame = self.panelView.bounds
        self.panelView.addSubview(panelBlur)
        self.contentView.addSubview(self.panelView)

        self.panelOutline.frame = self.panelView.frame
        self.panelOutline.path = domePath.cgPath
        self.panelOutline.fillColor = UIColor.clear.cgColor
        self.panelOutline.strokeColor = UIColor.white.withAlphaComponent(isDark ? 0.18 : 0.6).cgColor
        self.panelOutline.lineWidth = 1.0
        self.contentView.layer.addSublayer(self.panelOutline)

        // Hour ticks and labels along the arc.
        let ticksPath = UIBezierPath()
        for index in 0 ... 23 {
            let angle = self.angle(forHour: index)
            let isMajor = index % 6 == 0 || index == 23
            ticksPath.move(to: self.point(angle: angle, distance: radius - (isMajor ? 20.0 : 13.0)))
            ticksPath.addLine(to: self.point(angle: angle, distance: radius - 7.0))
            if isMajor {
                let label = UILabel()
                label.text = "\(index)"
                label.font = UIFont.systemFont(ofSize: 13.0, weight: .semibold)
                label.textColor = primaryColor.withAlphaComponent(0.65)
                label.sizeToFit()
                label.center = self.point(angle: angle, distance: radius - 34.0)
                self.contentView.addSubview(label)
                self.hourLabels.append(label)
            }
        }
        self.ticksLayer.path = ticksPath.cgPath
        self.ticksLayer.strokeColor = primaryColor.withAlphaComponent(0.35).cgColor
        self.ticksLayer.lineWidth = 2.0
        self.ticksLayer.lineCap = .round
        self.contentView.layer.addSublayer(self.ticksLayer)

        // Hands with round grips at the ends: the long one is the hour, the short one the minutes.
        self.setupHand(self.hourHand, length: self.hourHandLength, width: 6.0, gripSize: 16.0, color: accentColor)
        self.setupHand(self.minuteHand, length: self.minuteHandLength, width: 4.0, gripSize: 12.0, color: primaryColor.withAlphaComponent(0.8))

        // Hub with the selected time.
        self.hubView.frame = CGRect(x: self.pivot.x - hubRadius, y: self.pivot.y - hubRadius, width: hubRadius * 2.0, height: hubRadius * 2.0)
        self.hubView.backgroundColor = accentColor
        self.hubView.layer.cornerRadius = hubRadius
        self.hubView.layer.shadowColor = UIColor.black.cgColor
        self.hubView.layer.shadowOpacity = 0.2
        self.hubView.layer.shadowRadius = 8.0
        self.hubView.layer.shadowOffset = CGSize(width: 0.0, height: 3.0)
        self.contentView.addSubview(self.hubView)

        self.timeLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 19.0, weight: .bold)
        self.timeLabel.textColor = .white
        self.timeLabel.textAlignment = .center
        self.timeLabel.frame = CGRect(x: 0.0, y: 17.0, width: hubRadius * 2.0, height: 24.0)
        self.hubView.addSubview(self.timeLabel)

        self.dayLabel.font = UIFont.systemFont(ofSize: 11.0, weight: .medium)
        self.dayLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        self.dayLabel.textAlignment = .center
        self.dayLabel.frame = CGRect(x: 4.0, y: 41.0, width: hubRadius * 2.0 - 8.0, height: 15.0)
        self.dayLabel.adjustsFontSizeToFitWidth = true
        self.hubView.addSubview(self.dayLabel)

        // Bell on top of the dome.
        let bellSize: CGFloat = 46.0
        self.bellView.frame = CGRect(x: self.pivot.x - bellSize / 2.0, y: self.pivot.y - radius - bellSize / 2.0, width: bellSize, height: bellSize)
        self.bellView.layer.cornerRadius = bellSize / 2.0
        self.bellView.layer.cornerCurve = .circular
        if !bellIsGlass {
            // Liquid Glass draws its own edge; the blur fallback gets a thin outline.
            self.bellView.clipsToBounds = true
            self.bellView.layer.borderWidth = 1.0
            self.bellView.layer.borderColor = UIColor.white.withAlphaComponent(isDark ? 0.18 : 0.6).cgColor
        }
        self.contentView.addSubview(self.bellView)
        self.bellButton.frame = self.bellView.frame
        self.bellButton.addTarget(self, action: #selector(self.bellPressed), for: .touchUpInside)
        self.contentView.addSubview(self.bellButton)

        // The send button turns into a "schedule" button.
        self.confirmButton.frame = sendButtonFrame.insetBy(dx: -4.0, dy: -4.0)
        self.confirmButton.backgroundColor = accentColor
        self.confirmButton.layer.cornerRadius = self.confirmButton.frame.height / 2.0
        self.confirmButton.tintColor = .white
        self.confirmButton.setImage(UIImage(systemName: "clock.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18.0, weight: .semibold)), for: .normal)
        self.confirmButton.addTarget(self, action: #selector(self.confirmPressed), for: .touchUpInside)
        self.addSubview(self.confirmButton)

        self.updateBell()
        self.updateHands(animated: false)
        self.selectionFeedback.prepare()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func domePath(width: CGFloat, height: CGFloat, radius: CGFloat, cornerRadius: CGFloat) -> UIBezierPath {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0.0, y: radius))
        path.addArc(withCenter: CGPoint(x: radius, y: radius), radius: radius, startAngle: CGFloat.pi, endAngle: 0.0, clockwise: true)
        path.addLine(to: CGPoint(x: width, y: height - cornerRadius))
        path.addQuadCurve(to: CGPoint(x: width - cornerRadius, y: height), controlPoint: CGPoint(x: width, y: height))
        path.addLine(to: CGPoint(x: cornerRadius, y: height))
        path.addQuadCurve(to: CGPoint(x: 0.0, y: height - cornerRadius), controlPoint: CGPoint(x: 0.0, y: height))
        path.close()
        return path
    }

    private func setupHand(_ hand: UIView, length: CGFloat, width: CGFloat, gripSize: CGFloat, color: UIColor) {
        hand.backgroundColor = color
        hand.layer.cornerRadius = width / 2.0
        hand.layer.anchorPoint = CGPoint(x: 0.5, y: 1.0)
        hand.bounds = CGRect(x: 0.0, y: 0.0, width: width, height: length)
        hand.center = self.pivot

        let grip = UIView(frame: CGRect(x: (width - gripSize) / 2.0, y: -gripSize / 2.0, width: gripSize, height: gripSize))
        grip.backgroundColor = color
        grip.layer.cornerRadius = gripSize / 2.0
        grip.layer.borderColor = UIColor.white.cgColor
        grip.layer.borderWidth = 2.0
        hand.addSubview(grip)

        self.contentView.addSubview(hand)
    }

    // Angles are measured from the right (0) to the left (pi) over the top.
    private func angle(forHour hour: Int) -> CGFloat {
        return CGFloat.pi - CGFloat(hour) / 23.0 * CGFloat.pi
    }

    private func angle(forMinute minute: Int) -> CGFloat {
        return CGFloat.pi - CGFloat(minute) / 55.0 * CGFloat.pi
    }

    private func point(angle: CGFloat, distance: CGFloat) -> CGPoint {
        return CGPoint(x: self.pivot.x + cos(angle) * distance, y: self.pivot.y - sin(angle) * distance)
    }

    private func handTransform(angle: CGFloat) -> CGAffineTransform {
        return CGAffineTransform(rotationAngle: CGFloat.pi / 2.0 - angle)
    }

    private func targetDate() -> Date {
        let calendar = Calendar.current
        let now = Date()
        var date = calendar.date(bySettingHour: self.hour, minute: self.minute, second: 0, of: now) ?? now
        if date.timeIntervalSince(now) < 60.0 {
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        }
        return date
    }

    private func updateHands(animated: Bool) {
        let hourTransform = self.handTransform(angle: self.angle(forHour: self.hour))
        let minuteTransform = self.handTransform(angle: self.angle(forMinute: self.minute))
        if animated {
            UIView.animate(withDuration: 0.25, delay: 0.0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.0, options: [.beginFromCurrentState, .allowUserInteraction], animations: {
                self.hourHand.transform = hourTransform
                self.minuteHand.transform = minuteTransform
            }, completion: nil)
        } else {
            self.hourHand.transform = hourTransform
            self.minuteHand.transform = minuteTransform
        }

        self.timeLabel.text = String(format: "%02d:%02d", self.hour, self.minute)
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        self.dayLabel.text = formatter.string(from: self.targetDate())
    }

    private func updateBell() {
        let name = self.silent ? "bell.slash.fill" : "bell.fill"
        self.bellButton.setImage(UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18.0, weight: .semibold)), for: .normal)
        self.bellButton.tintColor = self.silent ? self.primaryColor.withAlphaComponent(0.55) : self.accentColor
    }

    @objc private func bellPressed() {
        self.silent = !self.silent
        self.updateBell()
        self.selectionFeedback.selectionChanged()
        self.bellView.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        self.bellButton.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        UIView.animate(withDuration: 0.4, delay: 0.0, usingSpringWithDamping: 0.5, initialSpringVelocity: 0.0, options: [], animations: {
            self.bellView.transform = .identity
            self.bellButton.transform = .identity
        }, completion: nil)
    }

    @objc private func confirmPressed() {
        let timestamp = Int32(self.targetDate().timeIntervalSince1970)
        let silent = self.silent
        let onSchedule = self.onSchedule
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        self.dismiss(completion: {
            onSchedule?(timestamp, silent)
        })
    }

    // MARK: Dragging the hands

    private func handleTouch(at location: CGPoint, began: Bool) {
        let dx = location.x - self.pivot.x
        let dy = self.pivot.y - location.y
        var angle = atan2(max(dy, 0.0), dx)
        angle = min(max(angle, 0.0), CGFloat.pi)
        let fraction = (CGFloat.pi - angle) / CGFloat.pi

        if began {
            let distance = sqrt(dx * dx + dy * dy)
            self.activeHand = distance > (self.hourHandLength + self.minuteHandLength) / 2.0 ? .hour : .minute
        }
        guard let activeHand = self.activeHand else {
            return
        }
        switch activeHand {
        case .hour:
            let value = Int((fraction * 23.0).rounded())
            if value != self.hour {
                self.hour = value
                self.selectionFeedback.selectionChanged()
                self.updateHands(animated: true)
            }
        case .minute:
            let value = Int((fraction * 11.0).rounded()) * 5
            if value != self.minute {
                self.minute = value
                self.selectionFeedback.selectionChanged()
                self.updateHands(animated: true)
            }
        }
    }

    private func isOnDial(_ location: CGPoint) -> Bool {
        return self.panelView.frame.insetBy(dx: -12.0, dy: -12.0).contains(location)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let location = touches.first?.location(in: self) else {
            return
        }
        if self.isOnDial(location) {
            self.handleTouch(at: location, began: true)
        } else {
            self.activeHand = nil
            self.dismiss(completion: {})
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let location = touches.first?.location(in: self) else {
            return
        }
        self.handleTouch(at: location, began: false)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        self.activeHand = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        self.activeHand = nil
    }

    // MARK: Appearance

    private var collapsedTransform: CGAffineTransform {
        let scale: CGFloat = 0.12
        return CGAffineTransform(translationX: self.sendButtonFrame.midX - self.pivot.x, y: self.sendButtonFrame.midY - self.pivot.y + self.radius * 0.5).scaledBy(x: scale, y: scale)
    }

    func animateIn() {
        // The dome grows out of the send button with a spring, like Telegram's menus.
        self.contentView.transform = self.collapsedTransform
        self.contentView.alpha = 0.0
        self.confirmButton.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        self.hourHand.transform = self.handTransform(angle: CGFloat.pi)
        self.minuteHand.transform = self.handTransform(angle: CGFloat.pi)
        self.bellView.transform = CGAffineTransform(scaleX: 0.01, y: 0.01)
        self.bellButton.transform = CGAffineTransform(scaleX: 0.01, y: 0.01)
        self.hubView.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
        for label in self.hourLabels {
            label.alpha = 0.0
        }
        self.ticksLayer.strokeEnd = 0.0
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        UIView.animate(withDuration: 0.2, animations: {
            self.dimView.alpha = 1.0
            self.contentView.alpha = 1.0
        })
        UIView.animate(withDuration: 0.6, delay: 0.0, usingSpringWithDamping: 0.72, initialSpringVelocity: 0.4, options: [.allowUserInteraction], animations: {
            self.contentView.transform = .identity
            self.confirmButton.transform = .identity
        }, completion: nil)
        UIView.animate(withDuration: 0.5, delay: 0.08, usingSpringWithDamping: 0.6, initialSpringVelocity: 0.0, options: [.allowUserInteraction], animations: {
            self.hubView.transform = .identity
        }, completion: nil)

        // Ticks are drawn along the arc, the numbers follow one by one.
        let ticksAnimation = CABasicAnimation(keyPath: "strokeEnd")
        ticksAnimation.fromValue = 0.0
        ticksAnimation.toValue = 1.0
        ticksAnimation.duration = 0.5
        ticksAnimation.beginTime = CACurrentMediaTime() + 0.1
        ticksAnimation.fillMode = .backwards
        ticksAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        self.ticksLayer.strokeEnd = 1.0
        self.ticksLayer.add(ticksAnimation, forKey: "draw")
        for (index, label) in self.hourLabels.enumerated() {
            UIView.animate(withDuration: 0.25, delay: 0.15 + Double(index) * 0.06, options: [.allowUserInteraction], animations: {
                label.alpha = 1.0
            }, completion: nil)
        }

        // The bell pops in, the hands sweep into place.
        UIView.animate(withDuration: 0.5, delay: 0.25, usingSpringWithDamping: 0.55, initialSpringVelocity: 0.0, options: [.allowUserInteraction], animations: {
            self.bellView.transform = .identity
            self.bellButton.transform = .identity
        }, completion: nil)
        let hourTransform = self.handTransform(angle: self.angle(forHour: self.hour))
        let minuteTransform = self.handTransform(angle: self.angle(forMinute: self.minute))
        UIView.animate(withDuration: 0.8, delay: 0.15, usingSpringWithDamping: 0.65, initialSpringVelocity: 0.0, options: [.allowUserInteraction], animations: {
            self.hourHand.transform = hourTransform
            self.minuteHand.transform = minuteTransform
        }, completion: nil)
    }

    private func dismiss(completion: @escaping () -> Void) {
        if self.isDismissing {
            return
        }
        self.isDismissing = true
        self.isUserInteractionEnabled = false
        UIView.animate(withDuration: 0.25, delay: 0.0, options: [.curveEaseIn], animations: {
            self.contentView.transform = self.collapsedTransform
            self.contentView.alpha = 0.0
            self.dimView.alpha = 0.0
            self.confirmButton.alpha = 0.0
            self.confirmButton.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        }, completion: { _ in
            completion()
            self.onClosed?()
        })
    }
}
