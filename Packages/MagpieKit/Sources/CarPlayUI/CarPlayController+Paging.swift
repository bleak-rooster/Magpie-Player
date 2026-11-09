#if os(iOS) && canImport(CarPlay)
import CarPlay
import MagpieCore

// Round 24 item 8 (owner, 2026-11-08): "CarPlay lists stop at about 10 items". Every list is laid out for the car's
// ceiling as a page (ListDiff.swift's `clamp`, D231): "More…" and "Previous…" open the next or previous page in place
// of this one (pop, then push), so CarPlay's template depth never grows (D232); from a tab's own list the first page
// is pushed, within D12's budget. CarPlayController.swift only calls `fitPage` (in `apply`) and `openPage` (in `open`).
extension CarPlayController {
    /// The page of `sections` this list shows, within the car's limits now. A song group's page arrives paged already
    /// (it reads only its own songs, `songPageFetcher`).
    func fitPage(_ sections: [CPSectionModel], for binding: ListBinding) -> [CPSectionModel] {
        let limits = listLimits()
        guard !CPPager.isPaged(sections) else { return sections }
        let page = Self.page(of: binding)
        return clamp(sections, maxItems: limits.items, maxSections: limits.sections, start: page.start,
                     link: CPPageRef.action(base: page.base, baseTitle: page.baseTitle))
    }

    /// What list `binding` shows, under which title, and from which row.
    static func page(of binding: ListBinding) -> (base: CPDestination?, baseTitle: String, start: Int) {
        if case .page(let ref) = binding.destination { return (ref.base, ref.baseTitle, ref.start) }
        return (binding.destination, binding.template.title ?? "", 0)
    }

    /// Opens a page of the list on screen. It shows what that list read (nothing is read again; a song group reads
    /// the page's songs). A pushed list is replaced: popped, then the page pushed once the pop went through (Z3 review
    /// M5's rule: a refused pop pushes nothing). A tab's own list pushes its page.
    func openPage(_ ref: CPPageRef) {
        let top = interface.topTemplate
        let shown: CPTemplate? = if let tabs = top as? CPTabBarTemplate { tabs.selectedTemplate } else { top }
        guard let shown, let current = bindings[ObjectIdentifier(shown)] else { return }
        let template = CPListTemplate(title: ref.title, sections: [])
        template.showsSpinnerWhileEmpty = true
        let binding = bind(template)
        binding.destination = .page(ref)
        let reads: (@MainActor () async throws -> Content)? = if case .songRange = ref.base {
            azFetcher(for: .page(ref), into: binding)
        } else {
            nil
        }
        if reads == nil {
            guard let content = current.content else {
                bindings[ObjectIdentifier(template)] = nil
                return
            }
            binding.content = content
            binding.relayout = current.relayout
            binding.limits = current.limits
        }
        let show = { @MainActor [weak self] in
            guard let self else { return }
            self.interface.pushTemplate(template, animated: true, completion: nil)
            if let reads { self.load(binding, reads) } else { Task { await self.refresh(binding) } }
        }
        let replaces = !(top is CPTabBarTemplate) && top === shown && interface.templates.count > 1
        guard replaces, let below = interface.templates.dropLast().last else {
            guard CPNavigator.allowsPush(atDepth: browseDepth) else {
                bindings[ObjectIdentifier(template)] = nil
                return
            }
            return show()
        }
        interface.pop(to: below, animated: false) { [weak self] popped, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard popped, self.interface.topTemplate === below else {
                    self.bindings[ObjectIdentifier(template)] = nil
                    return
                }
                show()
            }
        }
    }
}
#endif
