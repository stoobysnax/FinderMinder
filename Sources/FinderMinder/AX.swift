import ApplicationServices
import CoreGraphics

/// Small conveniences over the C Accessibility API.
extension AXUIElement {
    func value(_ attribute: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &v) == .success else { return nil }
        return v
    }

    func string(_ attribute: String) -> String? {
        value(attribute) as? String
    }

    func element(_ attribute: String) -> AXUIElement? {
        guard let v = value(attribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    func elements(_ attribute: String) -> [AXUIElement] {
        guard let v = value(attribute), CFGetTypeID(v) == CFArrayGetTypeID() else { return [] }
        return (v as? [AXUIElement]) ?? []
    }

    var role: String? { string(kAXRoleAttribute) }
    var subrole: String? { string(kAXSubroleAttribute) }
    var children: [AXUIElement] { elements(kAXChildrenAttribute) }
    var parent: AXUIElement? { element(kAXParentAttribute) }

    var pid: pid_t {
        var p: pid_t = 0
        AXUIElementGetPid(self, &p)
        return p
    }

    /// Frame in global screen coordinates (top-left origin, same as CGEvent).
    var frame: CGRect? {
        guard let p = value(kAXPositionAttribute), let s = value(kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    var attributeNames: [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(self, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    /// Breadth-first search, bounded by depth and total node count.
    func descendants(maxDepth: Int, limit: Int = 3000, where predicate: (AXUIElement) -> Bool) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var queue: [(AXUIElement, Int)] = children.map { ($0, 1) }
        var visited = 0
        while !queue.isEmpty && visited < limit {
            let (node, depth) = queue.removeFirst()
            visited += 1
            if predicate(node) { result.append(node) }
            if depth < maxDepth {
                queue.append(contentsOf: node.children.map { ($0, depth + 1) })
            }
        }
        return result
    }

    func firstDescendant(maxDepth: Int, limit: Int = 3000, where predicate: (AXUIElement) -> Bool) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = children.map { ($0, 1) }
        var visited = 0
        while !queue.isEmpty && visited < limit {
            let (node, depth) = queue.removeFirst()
            visited += 1
            if predicate(node) { return node }
            if depth < maxDepth {
                queue.append(contentsOf: node.children.map { ($0, depth + 1) })
            }
        }
        return nil
    }

    /// First human-readable text found in or under this element (e.g. a file name in a row).
    var displayText: String {
        for attr in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            if let s = string(attr), !s.isEmpty { return s }
        }
        let textRoles: Set<String> = [kAXStaticTextRole, kAXTextFieldRole]
        if let t = firstDescendant(maxDepth: 4, limit: 40, where: { textRoles.contains($0.role ?? "") }),
           let s = t.string(kAXValueAttribute) {
            return s
        }
        return ""
    }
}
