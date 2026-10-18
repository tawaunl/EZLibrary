import Foundation
import Testing
@testable import EZLibraryCore

private func volume(_ uuid: String, at path: String, name: String = "Drive") -> BackupDeviceMemory.Volume {
    BackupDeviceMemory.Volume(uuid: uuid, name: name, mountPoint: URL(fileURLWithPath: path))
}

@Test func aRecordedDriveIsRecognisedAtADifferentMountPath() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let firstMount = root.appendingPathComponent("Volumes/Backup")
    let secondMount = root.appendingPathComponent("Volumes/Backup 1")
    for mount in [firstMount, secondMount] {
        try FileManager.default.createDirectory(
            at: mount.appendingPathComponent("DJ/Backups"), withIntermediateDirectories: true
        )
    }
    defer { try? FileManager.default.removeItem(at: root) }

    let memory = BackupDeviceMemory(defaults: TestDefaults.inMemory())
    memory.record(
        destination: firstMount.appendingPathComponent("DJ/Backups"),
        on: volume("UUID-A", at: firstMount.path)
    )

    let resolved = memory.destination(for: volume("UUID-A", at: secondMount.path))
    #expect(
        resolved?.resolvingSymlinksInPath().path
            == secondMount.appendingPathComponent("DJ/Backups").resolvingSymlinksInPath().path
    )
}

@Test func anUnknownDriveIsNotSwitchedTo() {
    let memory = BackupDeviceMemory(defaults: TestDefaults.inMemory())
    memory.record(destination: URL(fileURLWithPath: "/Volumes/A"), on: volume("UUID-A", at: "/Volumes/A"))
    #expect(memory.destination(for: volume("UUID-B", at: "/Volumes/B")) == nil)
}

@Test func aMissingRememberedFolderFallsBackToTheDriveRoot() throws {
    let mount = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: mount) }

    let memory = BackupDeviceMemory(defaults: TestDefaults.inMemory())
    memory.record(destination: mount.appendingPathComponent("Gone"), on: volume("UUID-A", at: mount.path))
    let resolved = memory.destination(for: volume("UUID-A", at: mount.path))
    #expect(resolved?.resolvingSymlinksInPath().path == mount.resolvingSymlinksInPath().path)
}

@Test func recordingTheSameDriveAgainReplacesItsEntry() {
    let memory = BackupDeviceMemory(defaults: TestDefaults.inMemory())
    let drive = volume("UUID-A", at: "/Volumes/A")
    memory.record(destination: URL(fileURLWithPath: "/Volumes/A/One"), on: drive)
    memory.record(destination: URL(fileURLWithPath: "/Volumes/A/Two"), on: drive)
    #expect(memory.devices.count == 1)
    #expect(memory.devices.first?.relativePath == "Two")
}

@Test func aForgottenDriveIsNoLongerSwitchedTo() {
    let memory = BackupDeviceMemory(defaults: TestDefaults.inMemory())
    let drive = volume("UUID-A", at: "/Volumes/A")
    let other = volume("UUID-B", at: "/Volumes/B")
    memory.record(destination: URL(fileURLWithPath: "/Volumes/A"), on: drive)
    memory.record(destination: URL(fileURLWithPath: "/Volumes/B"), on: other)

    memory.forget(volumeUUID: "UUID-A")

    #expect(memory.device(forVolumeUUID: "UUID-A") == nil)
    #expect(memory.destination(for: drive) == nil)
    #expect(memory.device(forVolumeUUID: "UUID-B") != nil)
}
