// Portions adapted from Dictus (https://github.com/getdictus/dictus-ios),
// DictusKeyboard/KeyboardViewController.swift (lifecycle rules) and DictusKeyboard/KeyboardLifecycleProbe.swift
// (isAttachedToWindow). MIT License, Copyright (c) 2026 PIVI Solutions. See THIRD_PARTY_NOTICES.md.
import UIKit
import SwiftUI

final class KeyboardViewController: UIInputViewController {
    private var host: UIHostingController<KeyboardView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        let h = UIHostingController(rootView: KeyboardView())
        h.view.backgroundColor = .clear
        h.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(h)
        view.addSubview(h.view)
        NSLayoutConstraint.activate([
            h.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            h.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            h.view.topAnchor.constraint(equalTo: view.topAnchor),
            h.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        h.didMove(toParent: self)
        let height = view.heightAnchor.constraint(equalToConstant: 260)
        height.priority = UILayoutPriority(999)
        height.isActive = true
        host = h
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let d = AppGroup.defaults
        if hasFullAccess {
            d.set(Date().timeIntervalSince1970, forKey: Keys.kbSeenAt)
            d.set(AppGroup.containerURL != nil, forKey: Keys.kbContainerOK)
        }
        d.set(FMCleanup.shared.availabilitySlug(), forKey: Keys.fmAvailability)
        FMCleanup.shared.logVariantOnce()
        d.synchronize()
        KeyboardState.shared.attach(self)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Do NOT reset dictation state here (#142: iOS calls this just before foregrounding the app on a cold start).
        KeyboardState.shared.detached(self)
    }
}

extension UIInputViewController {
    /// The controller's view (or its inputView) is in a window: iOS churns controllers, so ask the view.
    var isAttachedToWindow: Bool { view.window != nil || inputView?.window != nil }
}
