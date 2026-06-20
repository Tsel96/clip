import AppKit

/// A3 seam — the `NSCollectionViewDataSource` methods, split out of
/// `CollectionCanvas.Coordinator` so the data-source concern lives apart from
/// the camera + apply logic. Identical code, separate file. The conformance is
/// declared on the Coordinator itself; these implement it.
extension CollectionCanvas.Coordinator {

    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        nodes.count
    }

    func collectionView(_ cv: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = cv.makeItem(withIdentifier: Self.itemID, for: indexPath)
        if let hosting = item as? HostingCollectionItem, indexPath.item < nodes.count {
            let node = nodes[indexPath.item]
            hosting.cardView.nodeID = node.id
            hosting.cardView.coordinator = self
            hosting.setContent(node: node, swiftUI: config.content(node),
                               isEditing: config.editingTextNodeID == node.id)
            hosting.cardView.updateShadow()
            hosting.cardView.updateChrome()
            if pendingAppearIDs.remove(node.id) != nil {
                hosting.cardView.wantsAppear = true   // fired in layout() when bounds are set
            }
        }
        return item
    }
}
