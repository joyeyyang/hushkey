import AppKit
import ApplicationServices

/// The Accessibility half of the spoken edit, checked against a real text
/// field.
///
/// The spoken edit ends by replacing the text the app pasted last, in
/// somebody else's editor. Everything before this -- finding the line, asking
/// the model to rewrite it -- is plain string work and is covered by the unit
/// tests. This is the part that talks to another process: it reads the focused
/// element's value over Accessibility, finds the insertion inside it, selects
/// it, and pastes over it.
///
/// That part cannot be unit tested, because it needs a focused text field and
/// a process with Accessibility permission. So it runs in the app, against a
/// real `NSTextField` in a real window, with the real
/// `TextInjector.replaceLastInsertion`.
///
/// What it proves, one case at a time:
///
///  * the pasted text is FOUND in the field and replaced, not appended to;
///  * when the same text appears twice, the one at the caret is the one that
///    is replaced -- the wrong one being replaced is the expensive mistake;
///  * text the user typed AFTER the insertion is left alone;
///  * a field that does not expose its text is refused rather than guessed
///    at, and the result is left on the clipboard.
///
/// Enabled by `OVC_SELFTEST_AX`. The app needs Accessibility permission for
/// this, and the installed app has it.
enum AXSelfTest {

    /// One case: the field's text, where the caret sits, the text that was
    /// pasted, what should be there afterwards.
    private struct Case {
        let name: String
        let fieldText: String
        /// The caret position, in UTF-16 units. nil means the end of the text.
        let caret: Int?
        let pasted: String
        let replacement: String
        /// What the field should hold afterwards. nil means the replacement
        /// could NOT be made -- the field must be untouched and the result must
        /// be on the clipboard.
        let expected: String?
    }

    static func run() -> Never {
        var failures: [String] = []

        guard TextInjector.hasAccessibility else {
            print("AX SELFTEST FAIL: this process has no Accessibility permission")
            exit(1)
        }

        // The window has to be on screen and its field has to be the focused
        // element, because that is what the injector looks for.
        //
        // The app is already a REGULAR app for this run -- the activation
        // policy is set before anything starts, because an accessory app
        // cannot become the frontmost app and the posted Cmd+V would go
        // somewhere else entirely.
        NSApp.activate(ignoringOtherApps: true)

        let cases: [Case] = [
            Case(
                name: "replaces the pasted text",
                fieldText: "今天開會討論第四季時程",
                caret: nil,
                pasted: "今天開會討論第四季時程",
                replacement: "今天開會討論第五季時程",
                expected: "今天開會討論第五季時程"),
            Case(
                name: "replaces the last occurrence, not the first",
                fieldText: "今天開會，然後今天開會",
                caret: nil,
                pasted: "今天開會",
                replacement: "昨天開會",
                expected: "今天開會，然後昨天開會"),
            Case(
                name: "leaves what the user typed afterwards alone",
                fieldText: "今天開會，後來又補了一句",
                caret: 4,
                pasted: "今天開會",
                replacement: "昨天開會",
                expected: "昨天開會，後來又補了一句"),
            Case(
                name: "refuses when the pasted text is gone",
                fieldText: "使用者後來把那段字刪掉了",
                caret: nil,
                pasted: "今天開會",
                replacement: "昨天開會",
                expected: nil),
        ]

        for testCase in cases {
            let fixture = makeWindow(with: testCase.fieldText, caret: testCase.caret)
            defer { fixture.window.close() }

            // The field has to be focused AND on screen for the system-wide
            // focused element to be the field, and the window has to be KEY
            // for the posted Cmd+V to reach the field editor.
            //
            // A window that is not key does not take the focus, and the focus
            // can be taken away between cases, so it is re-established here
            // rather than trusted from the previous case.
            NSApp.activate(ignoringOtherApps: true)
            fixture.window.makeKeyAndOrderFront(nil)
            fixture.focusField()
            // The focus and the field editor's own setup are events too, so the
            // loop needs a turn before the injector looks for them.
            //
            // This WAITS for the field to actually BE the system-wide focused
            // element instead of sleeping a guessed 0.4 s. The first case of a run
            // is the slow one -- the app is still coming to the front -- and with a
            // fixed wait it intermittently started with `focused=<none>`: the
            // injector then refused (correctly: there was no focused text), and the
            // check blamed IT for a focus the test had not given it yet. Two runs
            // in a row disagreed about the same build, which is worse than either
            // answer.
            //
            // All four conditions are the injector's own preconditions, not
            // decoration: it reads the system-wide focused element (so the field
            // must be it), it needs the caret to say WHICH occurrence was pasted,
            // and the paste goes through the responder chain or a posted Cmd+V --
            // both of which need the app active and its window key.
            guard spinRunLoop(until: {
                NSApp.isActive && fixture.window.isKeyWindow
                    && fixture.focusedValue == testCase.fieldText && fixture.focusedCaret != nil
            }, timeout: 5) else {
                failures.append("\(testCase.name): the field never became the focused, "
                    + "key, active target (focused=\(fixture.focusedValue?.debugDescription ?? "<none>"), "
                    + "caret=\(fixture.focusedCaret.map(String.init) ?? "<none>"), "
                    + "key=\(fixture.window.isKeyWindow), active=\(NSApp.isActive))")
                continue
            }

            let result = TextInjector.replaceLastInsertion(
                expected: testCase.pasted, with: testCase.replacement)

            // The paste is a Cmd+V posted to the system, so it arrives as an
            // EVENT -- queued for this app's run loop. The test is running on
            // the main thread inside that same loop, so without giving the
            // loop a turn the event is never delivered and the field never
            // changes. The wait is for the event, not for the clock.
            spinRunLoop(for: 1.2)

            let after = fixture.accessibilityText
            // The state at the moment of the edit, kept for the failure message as
            // well as the verbose print: "the field did not change" has several
            // causes -- no focused text, no caret, the app not frontmost, or the
            // injector refusing -- and a failure that does not say which one sends
            // the reader back here with VERBOSE=1 for information the check already
            // had in hand.
            let diag = "focused=\(fixture.focusedValue?.debugDescription ?? "<none>") "
                + "caret=\(fixture.focusedCaret.map(String.init) ?? "<none>") "
                + "key=\(fixture.window.isKeyWindow) "
                + "active=\(NSApp.isActive) "
                + "result=\(result)"
            if ProcessInfo.processInfo.environment["OVC_SELFTEST_AX_VERBOSE"] != nil {
                let editorSelection = fixture.field.currentEditor()?.selectedRange
                print("ax diag [\(testCase.name)] \(diag) "
                    + "editorSel=\(editorSelection.map(String.init) ?? "<none>") after=\(after)")
            }
            switch testCase.expected {
            case let expected?:
                if after != expected {
                    failures.append("\(testCase.name): field is \(after.debugDescription), "
                        + "wanted \(expected.debugDescription) [\(diag)]")
                } else if !isPasted(result) {
                    failures.append("\(testCase.name): the replacement was not pasted, only copied")
                } else {
                    print("ok ax \(testCase.name)")
                }
            case nil:
                // The edit could not be proven, so the field must be untouched
                // and the result must be on the clipboard for the user.
                if after != testCase.fieldText {
                    failures.append("\(testCase.name): the field was changed to \(after.debugDescription) even though the edit was refused")
                } else if NSPasteboard.general.string(forType: .string) != testCase.replacement {
                    failures.append("\(testCase.name): the result is not on the clipboard")
                } else if isPasted(result) {
                    // A refusal that claims to have pasted is lying: the
                    // caller would tell the user the text was replaced when it
                    // was not, and the field still holds the old text.
                    failures.append("\(testCase.name): the refusal reported a paste")
                } else {
                    print("ok ax \(testCase.name) (refused, result on the clipboard)")
                }
            }
        }

        if failures.isEmpty {
            print("AX SELFTEST PASS")
            exit(0)
        }
        for failure in failures { print("FAIL \(failure)") }
        exit(1)
    }

    /// True when the injector pasted, rather than only copying.
    private static func isPasted(_ result: InjectionResult) -> Bool {
        if case .pasted = result { return true }
        return false
    }

    /// Gives the run loop a turn, for as long as it asks.
    ///
    /// The posted paste and the field editor's own changes both arrive as
    /// events. Sleeping instead would leave them queued: the clock passes but
    /// the event is not delivered, so the field keeps its old text and the
    /// check would blame the injector for something the test never let
    /// happen.
    private static func spinRunLoop(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    /// The same turn, repeated until `ready` holds or `timeout` runs out.
    ///
    /// For the one condition the test cannot simply wait a fixed time for: the
    /// window becoming key and its field becoming the system-wide focused element
    /// is the app's launch settling, and how long that takes depends on what else
    /// the machine is doing.
    private static func spinRunLoop(until ready: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ready() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return ready()
    }

    /// A window with one editable text field in it.
    ///
    /// The field is a plain `NSTextField`, which is what most editors the user
    /// types into are built from, and it exposes its value and selection over
    /// Accessibility -- so the injector sees exactly what it would see in
    /// another app.
    ///
    /// A window with one editable text field in it.
    ///
    /// The field is a plain `NSTextField`, which is what most editors the user
    /// types into are built from, and it exposes its value and selection over
    /// Accessibility -- so the injector sees exactly what it would see in
    /// another app.
    private struct FieldWindow {
        let window: NSWindow
        let field: NSTextField
        /// Where the caret goes once the field is being edited.
        let caret: Int

        init(text: String, caret: Int?) {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 80),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false)
            let field = NSTextField(string: text)
            field.isEditable = true
            field.isSelectable = true
            field.frame = NSRect(x: 12, y: 24, width: 456, height: 24)
            window.contentView?.addSubview(field)
            self.window = window
            self.field = field
            // The caret is where the user left it, and it is what tells the
            // injector WHICH occurrence of the pasted text is the one that was
            // pasted. nil means the end of the text, which is where a paste
            // leaves it.
            self.caret = caret ?? (text as NSString).length
        }

        /// Makes the field the one being edited, with the caret where the user
        /// left it.
        ///
        /// A text FIELD has no selection of its own -- the selection lives in
        /// its field editor, which exists only while the field is first
        /// responder. So the caret is set on the editor, after the field has
        /// been made first responder.
        func focusField() {
            window.makeFirstResponder(field)
            if let editor = field.currentEditor() {
                editor.selectedRange = NSRange(location: caret, length: 0)
            }
        }

        /// The focused element's text over Accessibility, or nil when the
        /// system-wide focused element is not readable.
        var focusedValue: String? {
            guard let element = focusedElement else { return nil }
            var text: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element, kAXValueAttribute as CFString, &text) == .success else { return nil }
            return text as? String
        }

        /// The focused element's selection over Accessibility.
        var focusedCaret: NSRange? {
            guard let element = focusedElement else { return nil }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
                let axValue = value, CFGetTypeID(axValue) == AXValueGetTypeID()
            else { return nil }
            var range = CFRange()
            guard AXValueGetValue(axValue as! AXValue, .cfRange, &range) else { return nil }
            return NSRange(location: range.location, length: range.length)
        }

        /// The system-wide focused element.
        private var focusedElement: AXUIElement? {
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                AXUIElementCreateSystemWide(),
                kAXFocusedUIElementAttribute as CFString,
                &focused) == .success,
                let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID()
            else { return nil }
            return element as! AXUIElement
        }

        /// The field's text after the edit, read back over Accessibility.
        ///
        /// Read over Accessibility rather than from the Swift object on
        /// purpose: the injector works through the Accessibility value, so
        /// that is the value that has to have changed.
        var accessibilityText: String {
            focusedValue ?? field.stringValue
        }
    }

    private static func makeWindow(with text: String, caret: Int?) -> FieldWindow {
        FieldWindow(text: text, caret: caret)
    }
}
