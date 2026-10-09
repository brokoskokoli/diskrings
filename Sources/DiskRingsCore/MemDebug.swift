import Darwin

/// Gibt den aktuellen Speicherbedarf (phys_footprint) auf stderr aus, wenn die
/// Umgebungsvariable `DISKRINGS_DEBUG_MEM` gesetzt ist. Für Messungen in
/// docs/PERFORMANCE.md.
func memDebug(_ label: String) {
    guard getenv("DISKRINGS_DEBUG_MEM") != nil else { return }
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return }
    fputs("[mem] \(label): footprint \(info.phys_footprint / 1_000_000) MB\n", stderr)
}

/// Gibt Knotenzahl und Dauer eines Live-Snapshots auf stderr aus, wenn
/// `DISKRINGS_DEBUG_SNAPSHOT` gesetzt ist (Kopie unter dem Lock, Aufbau).
func snapshotDebug(nodes: Int, copyNanos: UInt64, buildNanos: UInt64) {
    guard getenv("DISKRINGS_DEBUG_SNAPSHOT") != nil else { return }
    let copy = Double(copyNanos) / 1e6, build = Double(buildNanos) / 1e6
    fputs("[snapshot] \(nodes) Knoten, Kopie \(copy) ms, Aufbau \(build) ms\n", stderr)
}
