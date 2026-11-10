#if os(iOS) && canImport(CarPlay)
import CarPlay
import MagpieCore

// Round 24 item 8 (owner, 2026-11-08): "CarPlay lists stop at about 10 items". Every list is laid out for the car's
// ceiling as a page (ListDiff.swift's `clamp`, D231): "More…" and "Previous…" open the next or previous page in place
// of this one (pop, then push), so CarPlay's template depth never grows (D232); from a tab's own list the first page
// is pushed, within D12's budget. CarPlayController.swift only calls `fitPage` (in `apply`), `openPage` (in `open`) and
// `retitleIfStale` (in `templateDidAppear`), and holds `pageInFlight`.
extension CarPlayController {
    /// The page of `sections` this list shows, within the car's limits now. A song group's page arrives paged already
    /// (it reads only its own songs, `songPageFetcher`). Fix round 1 (M5): a list that isn't laid out by its own reads
    /// (A–Z lists and song groups keep theirs) records the limits it was paged for, so `reloadAZLists` only lays out
    /// again the lists whose limits really changed.
    func fitPage(_ sections: [CPSectionModel], for binding: ListBinding) -> [CPSectionModel] {
        let limits = listLimits()
        guard !CPPager.isPaged(sections) else { return sections }
        let page = Self.page(of: binding)
        if binding.relayout == nil, !Self.isLaidOutByItsReads(page.base) { binding.limits = limits }
        return clamp(sections, maxItems: limits.items, maxSections: limits.sections, start: page.start,
                     link: CPPageRef.action(base: page.base, baseTitle: page.baseTitle))
    }

    /// The A–Z lists and song groups: laid out (or read) for the limits their reads saw (`azFetcher`).
    static func isLaidOutByItsReads(_ base: CPDestination?) -> Bool {
        guard let base else { return false }
        if case .songRange = base { return true }
        return [.playlists, .artists, .albums, .songs].contains(base)
    }

    /// What list `binding` shows, under which title, and from which row.
    static func page(of binding: ListBinding) -> (base: CPDestination?, baseTitle: String, start: Int) {
        if case .page(let ref) = binding.destination { return (ref.base, ref.baseTitle, ref.start) }
        return (binding.destination, binding.template.title ?? "", 0)
    }

    /// Opens a page of the list on screen. It shows what that list read (nothing is read again; a song group reads
    /// the page's songs). A pushed list is replaced: popped, then the page pushed once the pop went through (Z3 review
    /// M5's rule: a refused pop pushes nothing). A tab's own list pushes its page.
    /// Fix round 1 (I1): a real pop answers later, so while one page is on its way any other tap is refused
    /// (`pageInFlight`), and a link is followed only from the list it belongs to.
    func openPage(_ ref: CPPageRef) {
        guard !pageInFlight else { return }
        let top = interface.topTemplate
        let shown: CPTemplate? = if let tabs = top as? CPTabBarTemplate { tabs.selectedTemplate } else { top }
        guard let shown, let current = bindings[ObjectIdentifier(shown)] else { return }
        let owner = Self.page(of: current)
        guard owner.base == ref.base, owner.baseTitle == ref.baseTitle else { return }
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
        pageInFlight = true
        interface.pop(to: below, animated: false) { [weak self] popped, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pageInFlight = false
                guard popped, self.interface.topTemplate === below else {
                    self.bindings[ObjectIdentifier(template)] = nil
                    return
                }
                show()
            }
        }
    }

    /// Fix round 1 (M3): a CarPlay list's title can't change, so a page on top whose place in the list moved with a new
    /// ceiling ("(2 of 2)" now "(3 of 3)") is opened again in its own place, holding the same first row. A page that is
    /// covered waits until it shows again (`templateDidAppear`).
    func retitleIfStale(_ template: CPTemplate) {
        guard !pageInFlight, interface.topTemplate === template, let binding = bindings[ObjectIdentifier(template)],
              let now = currentPage(of: binding), now.title != binding.template.title else { return }
        openPage(now)
    }

    /// The page `binding` should be under the car's limits now, or nil when it isn't a page (or holds nothing yet).
    func currentPage(of binding: ListBinding) -> CPPageRef? {
        guard case .page(let ref) = binding.destination else { return nil }
        let limits = listLimits()
        let link: CPPageLink?
        if case .songRange(_, let ranges)? = ref.base {
            link = CPPager.page(rowCount: ranges.reduce(0) { $0 + $1.count }, holding: ref.start, maxItems: limits.items,
                                maxSections: limits.sections)
        } else {
            guard let content = binding.content else { return nil }
            link = CPPager.page(content(player.queue.current?.song.id), holding: ref.start, maxItems: limits.items,
                                maxSections: limits.sections)
        }
        return link.map { CPPageRef(base: ref.base, baseTitle: ref.baseTitle, title: $0.title(listTitle: ref.baseTitle),
                                    start: $0.start) }
    }
}
#endif
